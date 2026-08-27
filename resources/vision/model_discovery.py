#!/usr/bin/env python3
"""Auto-discover Go models from opencode.ai and sync models.json.

Fetches GET https://opencode.ai/zen/go/v1/models (no auth, 10s timeout),
handles 3 response shapes, lowercases/dedups, then clones a template
entry per new id into ~/.codex-deepseek/models.json with visibility=hide
(newModelPolicy=off). Safe to run repeatedly (TTL 24h, atomic write, backup).

Usage:
  python3 model_discovery.py --sync            # fetch + merge
  python3 model_discovery.py --sync --force    # ignore TTL
  python3 model_discovery.py --dry-run         # print what would be added
  python3 model_discovery.py --list            # print remote ids
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

GO_MODELS_URL = "https://opencode.ai/zen/go/v1/models"
GO_DOCS_URLS = ["https://opencode.ai/docs/zh-cn/go/", "https://opencode.ai/docs/go/"]
TTL_SECONDS = 24 * 3600
TIMEOUT = 10
QUOTA_TTL = 12 * 3600

CODEX_HOME = Path.home() / ".codex-deepseek"
MODELS_JSON = CODEX_HOME / "models.json"
CACHE_DIR = Path.home() / ".local/share/agent-vision-toolkit"
CACHE_FILE = CACHE_DIR / "go_models_cache.json"
REASONING_REGISTRY = CACHE_DIR / "reasoning_registry.json"
GENERIC_REASONING = ["high"]

# Fallback 31 ids (2026-08-28 live snapshot)
FALLBACK_IDS = [
    "minimax-m3","minimax-m2.7","minimax-m2.5","kimi-k3","kimi-k2.7-code","kimi-k2.6",
    "longcat-2.0","kimi-k2.5","glm-5.2","glm-5.3-flash","glm-5.3","glm-5.1","glm-5",
    "deepseek-v4-pro","deepseek-v4-flash","deepseek-v4-flash-vision-exp",
    "qwen3.7-max","qwen3.8-max","qwen3.7-plus","qwen3.6-plus","qwen3.5-plus",
    "mimo-v2-pro","mimo-v2-omni","mimo-v2.5-pro","mimo-v2.5","hy3","hy3-preview",
    "gpt-5.6-luna","grok-4.5","grok-4.6","muse-spark-1.2-contributor",
]

GO_ALIASES = {"ox-alpha": "ox-alpha-free"}  # keep for compat, but not needed for new ids

# Display name -> id map for quota table (normalized)
DISPLAY_TO_ID = {
    "kimi k3": "kimi-k3",
    "qwen3.8 max": "qwen3.8-max",
    "grok 4.6": "grok-4.6",
    "glm-5.3-flash": "glm-5.3-flash",
    "glm-5.3": "glm-5.3",
    "glm-5.2": "glm-5.2",
    "glm-5.1": "glm-5.1",
    "kimi k2.7 code": "kimi-k2.7-code",
    "kimi k2.6": "kimi-k2.6",
    "longcat-2.0": "longcat-2.0",
    "mimo-v2.5": "mimo-v2.5",
    "mimo-v2.5-pro": "mimo-v2.5-pro",
    "minimax m3": "minimax-m3",
    "minimax m2.7": "minimax-m2.7",
    "muse spark 1.2 contributor": "muse-spark-1.2-contributor",
    "qwen3.7 max": "qwen3.7-max",
    "qwen3.7 plus": "qwen3.7-plus",
    "qwen3.6 plus": "qwen3.6-plus",
    "deepseek v4 pro": "deepseek-v4-pro",
    "deepseek v4 flash vision exp": "deepseek-v4-flash-vision-exp",
    "deepseek v4 flash": "deepseek-v4-flash",
    "hy3": "hy3",
    "gpt 5.6 luna": "gpt-5.6-luna",
    "deepseek v4 flash vision exp": "deepseek-v4-flash-vision-exp",
    "qwen3.8 max": "qwen3.8-max",
}

def _norm_display(s):
    return re.sub(r"\s+", " ", s.strip().lower().replace("-", " ").replace("–", " ")).strip()

FREE_TOKENS = {"-", "—", "", "限免", "免费", "无限", "∞", "不计配额", "限时免费", "限时免费不计配额"}

def _is_free_val(v):
    t = v.strip().lower()
    return t in FREE_TOKENS or t == "无限" or "限免" in t or "免费" in t

def _log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

QUOTA_CACHE_FILE = CACHE_DIR / "go_quota_cache.json"

def fetch_quota_ids(timeout=TIMEOUT):
    """Fetch Go quota table as ids; auto-detect free rows (三列全 -/限免 => free) like Widget."""
    for url in GO_DOCS_URLS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0","Accept":"*/*"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                html = r.read().decode(errors="replace")
            rows = re.findall(r"<tr>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>\s*</tr>", html)
            # filter header row and price table
            filtered = []
            for x in rows:
                if x[0].strip().lower() in ("model","模型"):
                    continue
                if "$" in x[1] or "$" in x[2] or "$" in x[3]:
                    continue
                # quota row: at least h5 and weekly are numeric or free token
                h5, wk, mo = x[1].strip(), x[2].strip(), x[3].strip()
                h5_is = h5.replace(",","").replace("，","").isdigit() or _is_free_val(h5)
                wk_is = wk.replace(",","").replace("，","").isdigit() or _is_free_val(wk)
                mo_is = mo.replace(",","").replace("，","").isdigit() or _is_free_val(mo)
                # need at least h5 or wk is quota/free, and mo is quota/free (Widget requires h5+weekly)
                if not (h5_is and wk_is):
                    # allow free row where all three are free
                    if _is_free_val(h5) and _is_free_val(wk) and _is_free_val(mo):
                        pass
                    else:
                        continue
                filtered.append(x)
            rows = filtered
            ids = []
            for disp, h5, wk, mo in rows:
                norm = _norm_display(disp)
                rid = DISPLAY_TO_ID.get(norm)
                if not rid:
                    # handle "Ox Alpha Free" etc with parentheses
                    norm2 = re.sub(r"\(.*\)", "", norm).strip()
                    rid = DISPLAY_TO_ID.get(norm2)
                if not rid:
                    rid = re.sub(r"[^a-z0-9.\-]", "-", norm).strip("-")
                    rid = re.sub(r"-+", "-", rid).strip("-")
                    rid = rid.replace("gpt-5-6-luna","gpt-5.6-luna")
                if rid and rid not in ids:
                    ids.append(rid)
            if len(ids) >= 10:
                try:
                    CACHE_DIR.mkdir(parents=True, exist_ok=True)
                    qc = {"ids": ids, "fetchedAt": int(time.time())}
                    (CACHE_DIR / "go_quota_cache.json").write_text(json.dumps(qc, ensure_ascii=False))
                except Exception:
                    pass
                _log(f"quota table {url} -> {len(ids)} ids")
                return ids
        except Exception as e:
            _log(f"quota fetch {url} failed: {e!r}")
            continue
    try:
        qc = json.loads((CACHE_DIR / "go_quota_cache.json").read_text())
        if time.time() - qc.get("fetchedAt",0) < QUOTA_TTL:
            ids = qc["ids"]
            _log(f"quota cache -> {len(ids)} ids")
            return ids
    except Exception:
        pass
    return None

def fetch_remote_ids(timeout=TIMEOUT):
    req = urllib.request.Request(GO_MODELS_URL, headers={"Accept": "*/*", "User-Agent": "model-discovery/1.0"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read()
            data = json.loads(raw.decode())
    except Exception as e:
        _log(f"fetch failed: {e!r}")
        return None
    # 3 shapes: {"data":[{"id":...}]}, ["id"], {"data":["id"]}
    ids = []
    if isinstance(data, list):
        for v in data:
            if isinstance(v, str):
                ids.append(v)
            elif isinstance(v, dict) and isinstance(v.get("id"), str):
                ids.append(v["id"])
    elif isinstance(data, dict):
        d = data.get("data")
        if isinstance(d, list):
            for v in d:
                if isinstance(v, str):
                    ids.append(v)
                elif isinstance(v, dict) and isinstance(v.get("id"), str):
                    ids.append(v["id"])
    # normalize
    seen = set()
    out = []
    for i in ids:
        n = i.strip().lower()
        if not n or n in seen:
            continue
        seen.add(n)
        out.append(n)
    return out if out else None

def load_cache():
    if not CACHE_FILE.exists():
        return None
    try:
        j = json.loads(CACHE_FILE.read_text())
        return j
    except Exception:
        return None

def save_cache(ids):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    j = {"ids": ids, "fetchedAt": int(time.time()), "fetchedAtStr": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    tmp = CACHE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(j, ensure_ascii=False, indent=2))
    tmp.replace(CACHE_FILE)

def is_cache_fresh(cache):
    if not cache:
        return False
    age = time.time() - cache.get("fetchedAt", 0)
    return age < TTL_SECONDS

def load_models_json():
    if not MODELS_JSON.exists():
        return {"models": []}
    return json.loads(MODELS_JSON.read_text())

def load_reasoning_registry():
    try:
        if REASONING_REGISTRY.exists():
            return json.loads(REASONING_REGISTRY.read_text())
    except Exception:
        pass
    return {}

def find_template(models, remote_id):
    # pick best template by prefix
    slug_map = {m["slug"]: m for m in models}
    def get(slug):
        return slug_map.get(slug)
    if remote_id.startswith("deepseek-"):
        return get("deepseek-v4-flash-go") or get("deepseek-v4-pro-go") or models[0]
    if remote_id.startswith("gpt-"):
        return get("gpt-5.6-luna-go") or get("deepseek-v4-flash-go") or models[0]
    if remote_id.startswith("muse-"):
        return get("muse-spark-1.2-contributor-go") or models[0]
    if remote_id.startswith("mimo-"):
        return get("mimo-v2.5-go") or get("mimo-v2.5-pro-go") or models[0]
    if remote_id.startswith("glm-"):
        return get("glm-5-go") or get("glm-5.3-go") or models[0]
    if remote_id.startswith("hy3"):
        # hy3 native responses
        return get("glm-5-go") or models[0]
    # generic chat-adapted fallback: use mimo template (supports tool call, image, no search)
    return get("mimo-v2.5-go") or get("glm-5-go") or models[0]

def build_entry(template, remote_id, priority):
    e = copy.deepcopy(template)
    slug = remote_id + "-go"
    # handle alias collisions: ox-alpha already handled, but keep slug as remote_id-go
    e["slug"] = slug
    # display_name: Title + (Go)
    # e.g. kimi-k3 -> Kimi-K3 (Go)  or qwen3.7-max -> Qwen3.7-Max (Go)
    disp = remote_id.replace("-", " ").title().replace(" ", "-")
    # fixup known
    disp = disp.replace("Gpt-", "GPT-").replace("Muse-", "Muse ").replace("Mimo-", "MiMo-").replace("Glm-", "GLM-")
    e["display_name"] = f"{disp} (Go)"
    e["description"] = f"OpenCode Go subscription model ({remote_id}), routed via opencode.ai Zen/Go proxy. auto-discovered {time.strftime('%Y-%m-%d')}"
    e["priority"] = priority
    e["visibility"] = "hide"  # newModelPolicy=off
    # supports_search_tool: only deepseek/gpt/muse keep true, rest false
    if remote_id.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark")):
        e["supports_search_tool"] = True
        if "web_search_tool_type" not in e:
            e["web_search_tool_type"] = "text"
    else:
        e["supports_search_tool"] = False
        e.pop("web_search_tool_type", None)
    # reasoning: hand-written registry, fallback generic high only (zero probe)
    reg = load_reasoning_registry()
    levels = reg.get(remote_id)
    if levels is None:
        levels = GENERIC_REASONING
    # normalize to supported_reasoning_levels format
    descs = {
        "low": "Fast responses with lighter reasoning",
        "medium": "Balanced reasoning for everyday tasks",
        "high": "Extra high reasoning depth for complex problems",
        "xhigh": "Extended reasoning depth for harder tasks",
        "max": "Maximum reasoning depth for the hardest problems",
        "none": "No reasoning",
    }
    e["supported_reasoning_levels"] = [{"effort": lv, "description": descs.get(lv, lv)} for lv in levels]
    e["default_reasoning_level"] = levels[0] if levels else "high"
    # ensure required fields
    e["supported_in_api"] = True
    return e

def sync(force=False, dry_run=False):
    # quota table is the source of truth (限免 + 三段配额), not /v1/models
    qids = fetch_quota_ids()
    if qids:
        ids = qids
        _log(f"quota source {len(ids)} ids")
        # also refresh /v1/models cache for bookkeeping but not used for sync
        try:
            rids = fetch_remote_ids()
            if rids:
                save_cache(rids)
        except Exception:
            pass
    else:
        cache = load_cache()
        if not force and is_cache_fresh(cache):
            ids = cache["ids"]
            _log(f"cache fresh ({len(ids)} ids, age {int(time.time()-cache['fetchedAt'])}s), skip fetch")
        else:
            ids = fetch_remote_ids()
            if ids is None:
                _log("fetch failed, trying cache")
                if cache and cache.get("ids"):
                    ids = cache["ids"]
                    _log(f"using cached {len(ids)} ids")
                else:
                    ids = FALLBACK_IDS
                    _log(f"using fallback {len(ids)} ids")
            else:
                _log(f"fetched {len(ids)} remote ids")
                save_cache(ids)

    j = load_models_json()
    models = j.get("models", [])
    existing_slugs = {m["slug"] for m in models}
    max_prio = max((m.get("priority", 0) for m in models), default=0)

    # Only quota-driven sync: ids is quota source (24)
    to_add = []
    for rid in ids:
        slug = rid + "-go"
        if slug in existing_slugs:
            continue
        tmpl = find_template(models, rid)
        if not tmpl:
            _log(f"no template for {rid}, skip")
            continue
        entry = build_entry(tmpl, rid, max_prio + len(to_add) + 1)
        to_add.append(entry)

    # Prune wild Go models not in quota (乱七八糟的)
    quota_bare = set(ids)
    # keep native deepseek without -go? they are separate, but they are in quota as deepseek, keep them
    to_keep = []
    pruned = []
    for m in models:
        slug = m.get("slug","")
        if not slug.endswith("-go"):
            to_keep.append(m)
            continue
        bare = slug[:-3]
        if bare in quota_bare:
            to_keep.append(m)
        else:
            pruned.append(slug)
    if pruned:
        _log(f"prune wild not in quota: {pruned}")

    if not to_add and not pruned:
        _log("no new models to add and no prune")
        return 0

    if to_add:
        _log(f"will add {len(to_add)} models:")
        for e in to_add:
            _log(f"  + {e['slug']} (priority {e['priority']}) vis={e['visibility']}")

    if dry_run:
        _log(f"dry-run, would prune {len(pruned)} and add {len(to_add)}, not writing")
        return len(to_add)

    # backup
    bak = CODEX_HOME / f"models.json.bak.{time.strftime('%Y%m%d%H%M%S')}"
    if MODELS_JSON.exists():
        bak.write_bytes(MODELS_JSON.read_bytes())
        _log(f"backup -> {bak}")

    j["models"] = to_keep + to_add
    # re-assign priorities 1..N to keep order stable by quota order
    # map quota order for new, existing keep relative order
    quota_order = {rid:i for i,rid in enumerate(ids)}
    def prio_key(m):
        slug=m.get("slug","")
        bare=slug[:-3] if slug.endswith("-go") else slug
        return (quota_order.get(bare, 999), m.get("priority",999))
    j["models"].sort(key=prio_key)
    # re-number priorities sequentially
    for i,m in enumerate(j["models"], start=1):
        m["priority"]=i
        # ensure visibility list for quota models (including free)
        if m["slug"].endswith("-go") and m["slug"][:-3] in quota_bare:
            m["visibility"]="list"
    tmp = MODELS_JSON.with_suffix(".tmp")
    tmp.write_text(json.dumps(j, ensure_ascii=False, indent=2) + "\n")
    tmp.replace(MODELS_JSON)
    _log(f"wrote {MODELS_JSON} ({len(j['models'])} total) pruned {len(pruned)} added {len(to_add)}")
    return len(to_add)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sync", action="store_true", help="fetch and merge")
    ap.add_argument("--force", action="store_true", help="ignore TTL")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list", action="store_true", help="print remote ids and exit")
    args = ap.parse_args()
    if args.list:
        ids = fetch_remote_ids() or load_cache() or {"ids": FALLBACK_IDS}
        if isinstance(ids, dict):
            ids = ids["ids"]
        for i in ids:
            print(i)
        return
    if args.sync or args.dry_run:
        sync(force=args.force, dry_run=args.dry_run)
        return
    ap.print_help()

if __name__ == "__main__":
    main()
