#!/bin/zsh
# =============================================================================
# Codex 一键配置安装器（macOS）
# 双击本文件即可；也可在终端手动运行：
#   ./codex-oneclick-setup.command
# 高级参数（测试/无人值守）：
#   --noninteractive     使用 ONECLICK_GO_KEY / ONECLICK_DS_KEY /
#                        ONECLICK_GLM_KEY / ONECLICK_PASS 环境变量，不弹窗
#   --skip-patch         不重建 ChatGPT-Patched.app（只生成配置）
#   --skip-proxy-start   生成代理文件但不启动 launchd 服务
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/codex-oneclick-setup.log"
mkdir -p "$(dirname "$LOG")"

NONINTERACTIVE=0
SKIP_PATCH=0
SKIP_PROXY_START=0
for arg in "$@"; do
  case "$arg" in
    --noninteractive) NONINTERACTIVE=1 ;;
    --skip-patch) SKIP_PATCH=1 ;;
    --skip-proxy-start) SKIP_PROXY_START=1 ;;
  esac
done

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

die() {
  log "ERROR: $*"
  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    osascript - "$*" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Codex 一键配置安装器" buttons {"好"} default button "好" with icon stop
end run
APPLESCRIPT
  fi
  exit 1
}

ask_hidden() {
  osascript - "$1" "$2" "$3" <<'APPLESCRIPT'
on run argv
  set thePrompt to item 1 of argv
  set theTitle to item 2 of argv
  set theDefault to item 3 of argv
  set oldDelims to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "\\n"
  set theParts to every text item of thePrompt
  set AppleScript's text item delimiters to linefeed
  set thePrompt to theParts as text
  set AppleScript's text item delimiters to oldDelims
  try
    set theAnswer to text returned of (display dialog thePrompt with title theTitle default answer theDefault with hidden answer buttons {"取消", "继续"} default button "继续" cancel button "取消")
    return theAnswer
  on error
    return "__CANCEL__"
  end try
end run
APPLESCRIPT
}

ask_plain() {
  osascript - "$1" "$2" "$3" <<'APPLESCRIPT'
on run argv
  set thePrompt to item 1 of argv
  set theTitle to item 2 of argv
  set theDefault to item 3 of argv
  set oldDelims to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "\\n"
  set theParts to every text item of thePrompt
  set AppleScript's text item delimiters to linefeed
  set thePrompt to theParts as text
  set AppleScript's text item delimiters to oldDelims
  try
    set theAnswer to text returned of (display dialog thePrompt with title theTitle default answer theDefault buttons {"取消", "继续"} default button "继续" cancel button "取消")
    return theAnswer
  on error
    return "__CANCEL__"
  end try
end run
APPLESCRIPT
}

show_info() {
  osascript - "$1" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Codex 一键配置安装器" buttons {"好"} default button "好" with icon note
end run
APPLESCRIPT
}

# ---------------------------------------------------------------------------
# 1. 读取/收集三个 Key（全可选，但 Go 与 DeepSeek 至少一个）
# ---------------------------------------------------------------------------
CODEX_HOME="$HOME/.codex-deepseek"
ENV_FILE="$HOME/.config/agent-vision-toolkit/env"
PATCH_BASE="$HOME/.codex/picker-patch"
PASS_FILE="$PATCH_BASE/.keychain-pass"

EXISTING_GO="$(grep '^ZEN_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
EXISTING_DS="$(awk -F'"' '/^experimental_bearer_token *=/{print $2}' "$CODEX_HOME/config.toml" 2>/dev/null | head -1 || true)"
EXISTING_GLM="$(grep '^VISION_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"

GO_KEY=""
DS_KEY=""
GLM_KEY=""
PASS=""

if [[ "$NONINTERACTIVE" -eq 1 ]]; then
  GO_KEY="${ONECLICK_GO_KEY:-}"
  DS_KEY="${ONECLICK_DS_KEY:-}"
  GLM_KEY="${ONECLICK_GLM_KEY:-}"
  PASS="${ONECLICK_PASS:-}"
else
  GO_KEY="$(ask_hidden "OpenCode Go / Zen 订阅 Key（必填其一）\n\n请粘贴你的 sk-... key。\n\n缺这个 key 的后果：所有 *-go 模型（deepseek-go / mimo / glm / luna / muse 等）不会安装，只能使用官方 DeepSeek。" "① OpenCode Go Key" "")"
  [[ "$GO_KEY" == "__CANCEL__" ]] && die "已取消安装"
  DS_KEY="$(ask_hidden "DeepSeek 官方 API Key（可选）\n\n请粘贴 sk-... key。\n\n缺这个 key 的后果：官方 deepseek-v4-flash / deepseek-v4-pro 两个模型不会显示，默认模型会自动改走 Go 模型。" "② DeepSeek Key" "")"
  [[ "$DS_KEY" == "__CANCEL__" ]] && die "已取消安装"
  GLM_KEY="$(ask_hidden "智谱 GLM 视觉 Key（可选）\n\n请粘贴 open.bigmodel.cn 的 key（格式类似 1234.xxxx）。\n\n缺这个 key 的后果：Codex 文本对话不受影响，但发图片会失败；之后可随时补填到 ~/.config/agent-vision-toolkit/env。" "③ 智谱 GLM 视觉 Key" "")"
  [[ "$GLM_KEY" == "__CANCEL__" ]] && die "已取消安装"
fi

# 去空格；留空时回落到现有配置（重复安装/更新 key 场景）
GO_KEY="${GO_KEY// /}"
DS_KEY="${DS_KEY// /}"
GLM_KEY="${GLM_KEY// /}"
GO_KEY="${GO_KEY:-$EXISTING_GO}"
DS_KEY="${DS_KEY:-$EXISTING_DS}"
GLM_KEY="${GLM_KEY:-$EXISTING_GLM}"

if [[ -z "$GO_KEY" && -z "$DS_KEY" ]]; then
  die "至少需要 OpenCode Go 或 DeepSeek 其中一个 key，请重新运行安装器。"
fi
for k in "$GO_KEY" "$DS_KEY" "$GLM_KEY"; do
  if [[ -n "$k" && "${#k}" -lt 8 ]]; then
    die "检测到疑似无效的 key（长度过短），请检查后重试。"
  fi
done

HAS_GO=0; HAS_DS=0; HAS_GLM=0
[[ -n "$GO_KEY" ]] && HAS_GO=1
[[ -n "$DS_KEY" ]] && HAS_DS=1
[[ -n "$GLM_KEY" ]] && HAS_GLM=1

log "输入校验通过：Go=$HAS_GO DeepSeek=$HAS_DS GLM=$HAS_GLM"

# ---------------------------------------------------------------------------
# 2. 签名密码：优先复用，否则让用户输入本机开机密码（或自定义密码）
# ---------------------------------------------------------------------------
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  if [[ -f "$PASS_FILE" && -z "$PASS" ]]; then
    PASS="$(cat "$PASS_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "$PASS" && "$NONINTERACTIVE" -eq 1 ]]; then
    PASS="${ONECLICK_PASS:-}"
  fi
  if [[ -z "$PASS" ]]; then
    PASS="$(ask_hidden "这台 Mac 的开机密码（用于创建本地签名钥匙串）\n\n只会保存在 ~/.codex/picker-patch/.keychain-pass（权限 600），不会上传或联网。\n\n如果你不想用开机密码，也可以输入任意自定义密码，但请务必记好（升级副本时还会用到）。" "签名钥匙串密码" "")"
    [[ "$PASS" == "__CANCEL__" ]] && die "已取消安装"
    if [[ -z "$PASS" ]]; then
      die "没有输入签名密码，无法创建 ChatGPT-Patched 副本。"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. 依赖检查
# ---------------------------------------------------------------------------
for tool in python3 openssl clang security codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "缺少依赖：$tool。请先运行 xcode-select --install 安装命令行工具后重试。"
  fi
done
if [[ "$SKIP_PATCH" -eq 0 && ! -d "/Applications/ChatGPT.app" ]]; then
  die "没有找到 /Applications/ChatGPT.app。请先安装原版 Codex / ChatGPT 桌面版再运行。"
fi

# ---------------------------------------------------------------------------
# 4. 备份旧配置
# ---------------------------------------------------------------------------
TS="$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$CODEX_HOME" "$HOME/.codex"
for f in config.toml models.json AGENTS.md; do
  if [[ -f "$CODEX_HOME/$f" ]]; then
    cp -p "$CODEX_HOME/$f" "$CODEX_HOME/$f.bak.$TS" 2>/dev/null || true
  fi
done
if [[ -f "$HOME/.codex/AGENTS.md" ]]; then
  cp -p "$HOME/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md.bak.$TS" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 5. 生成 models.json（按 key 过滤 + 重排 priority）
# ---------------------------------------------------------------------------
MODEL_TMPL="$SCRIPT_DIR/resources/templates/models.json"
MODELS_OUT="$CODEX_HOME/models.json"
python3 - "$MODEL_TMPL" "$MODELS_OUT" "$HAS_GO" "$HAS_DS" <<'PY'
import json, sys
src, dst, has_go, has_ds = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
data = json.load(open(src))
models = []
for m in data["models"]:
    is_go = m["slug"].endswith("-go")
    if is_go and not has_go:
        continue
    if not is_go and not has_ds:
        continue
    models.append(m)
for i, m in enumerate(models, 1):
    m["priority"] = i
json.dump({"models": models}, open(dst, "w"), ensure_ascii=False, indent=2)
print(len(models))
PY
MODEL_COUNT="$(python3 -c 'import json;print(len(json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || echo 0)"
AVAIL_SLUGS="$(python3 -c 'import json;print(" ".join(m["slug"] for m in json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || true)"
log "models.json 已生成：$MODEL_COUNT 个模型"

# ---------------------------------------------------------------------------
# 6. 选择默认模型 / 记忆模型 / base_url / bearer
# ---------------------------------------------------------------------------
DEFAULT_MODEL=""
if [[ "$HAS_DS" -eq 1 ]]; then
  DEFAULT_MODEL="deepseek-v4-flash"
elif [[ "$AVAIL_SLUGS" == *"mimo-v2.5-go"* ]]; then
  DEFAULT_MODEL="mimo-v2.5-go"
elif [[ "$AVAIL_SLUGS" == *"deepseek-v4-flash-go"* ]]; then
  DEFAULT_MODEL="deepseek-v4-flash-go"
else
  DEFAULT_MODEL="${AVAIL_SLUGS%% *}"
fi

EXTRACT_MODEL=""
if [[ "$AVAIL_SLUGS" == *"mimo-v2.5-go"* ]]; then
  EXTRACT_MODEL="mimo-v2.5-go"
elif [[ "$AVAIL_SLUGS" == *"deepseek-v4-flash-go"* ]]; then
  EXTRACT_MODEL="deepseek-v4-flash-go"
elif [[ "$AVAIL_SLUGS" == *"deepseek-v4-flash"* ]]; then
  EXTRACT_MODEL="deepseek-v4-flash"
else
  EXTRACT_MODEL="${AVAIL_SLUGS%% *}"
fi

if [[ -z "$DEFAULT_MODEL" || -z "$EXTRACT_MODEL" ]]; then
  die "models.json 生成为空，请检查 key 是否有效。"
fi

USE_PROXY=0
if [[ "$HAS_GO" -eq 1 || "$HAS_GLM" -eq 1 ]]; then
  USE_PROXY=1
fi
if [[ "$USE_PROXY" -eq 1 ]]; then
  BASE_URL="http://127.0.0.1:19100"
else
  BASE_URL="https://api.deepseek.com/"
fi
if [[ "$HAS_DS" -eq 1 ]]; then
  BEARER="$DS_KEY"
else
  BEARER="$GO_KEY"
fi

python3 - "$SCRIPT_DIR/resources/templates/config.toml" "$CODEX_HOME/config.toml" \
  "$DEFAULT_MODEL" "$EXTRACT_MODEL" "$BASE_URL" "$BEARER" <<'PY'
import sys
src, dst, default_model, extract_model, base_url, bearer = sys.argv[1:7]
text = open(src).read()
text = text.replace("__DEFAULT_MODEL__", default_model)
text = text.replace("__REASONING_EFFORT__", "low")
text = text.replace("__BASE_URL__", base_url)
text = text.replace("__BEARER__", bearer)
text = text.replace("__EXTRACT_MODEL__", extract_model)
text = text.replace("__CONSOLIDATION_MODEL__", extract_model)
open(dst, "w").write(text)
PY
chmod 600 "$CODEX_HOME/config.toml"
log "config.toml 已生成（默认模型 $DEFAULT_MODEL，base_url $BASE_URL）"

# ---------------------------------------------------------------------------
# 7. AGENTS.md 全局规则
# ---------------------------------------------------------------------------
cp -p "$SCRIPT_DIR/resources/templates/AGENTS.md" "$CODEX_HOME/AGENTS.md"
cp -p "$SCRIPT_DIR/resources/templates/AGENTS.md" "$HOME/.codex/AGENTS.md"
log "AGENTS.md 已安装"

# ---------------------------------------------------------------------------
# 8. 视觉代理（有 Go 或 GLM 时安装）
# ---------------------------------------------------------------------------
PROXY_OK=0
if [[ "$USE_PROXY" -eq 1 ]]; then
  VISION_DIR="$HOME/.local/share/agent-vision-toolkit"
  mkdir -p "$VISION_DIR" "$HOME/.config/agent-vision-toolkit"
  cp -R "$SCRIPT_DIR/resources/vision/." "$VISION_DIR/" 2>/dev/null || true
  chmod +x "$VISION_DIR"/bin/* 2>/dev/null || true
  : > "$ENV_FILE"
  {
    if [[ "$HAS_GLM" -eq 1 ]]; then
      printf 'VISION_API_KEY=%s\n' "$GLM_KEY"
      printf 'VISION_BASE_URL=https://open.bigmodel.cn/api/paas/v4\n'
      printf 'VISION_MODEL=glm-4v-flash\n'
    else
      printf '# VISION_* 未配置：看图功能未启用\n'
    fi
    printf 'LANG=zh\n\n'
    printf 'ZEN_API_KEY=%s\n' "$GO_KEY"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  PY_BIN="$(command -v python3)"
  PLIST="$HOME/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  SKIP_FLAG=""
  if [[ "$HAS_GLM" -eq 0 ]]; then
    SKIP_FLAG="<string>--skip-vision-config-check</string>"
  fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.agent-vision-toolkit.proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY_BIN</string>
    <string>$VISION_DIR/vision_proxy.py</string>
    <string>--port</string><string>19100</string>
    <string>--upstream</string><string>https://api.deepseek.com/</string>
    <string>--env-file</string><string>$ENV_FILE</string>
    $SKIP_FLAG
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$VISION_DIR/proxy.log</string>
  <key>StandardErrorPath</key><string>$VISION_DIR/proxy.err.log</string>
</dict>
</plist>
EOF

  if [[ "$SKIP_PROXY_START" -eq 0 ]]; then
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    for _ in {1..30}; do
      if lsof -nP -iTCP:19100 -sTCP:LISTEN >/dev/null 2>&1; then
        PROXY_OK=1
        break
      fi
      sleep 1
    done
    if [[ "$PROXY_OK" -eq 1 ]]; then
      log "视觉代理已启动（127.0.0.1:19100）"
    else
      log "WARN: 视觉代理未在 30 秒内监听，请查看 $VISION_DIR/proxy.err.log"
    fi
  else
    PROXY_OK=1
    log "代理文件已生成（--skip-proxy-start，未启动服务）"
  fi
else
  log "无需视觉代理（纯官方 DeepSeek 直连）"
fi

# ---------------------------------------------------------------------------
# 9. ChatGPT-Patched.app 副本（patch）
# ---------------------------------------------------------------------------
PATCH_OK=0
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  mkdir -p "$PATCH_BASE/certs" "$PATCH_BASE/scripts"
  cp -p "$SCRIPT_DIR/resources/patch/patch.sh" "$PATCH_BASE/patch.sh"
  cp -p "$SCRIPT_DIR/resources/patch/ent2.plist" "$PATCH_BASE/certs/ent2.plist"
  chmod 755 "$PATCH_BASE/patch.sh"
  if [[ -n "$PASS" ]]; then
    printf '%s' "$PASS" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
  fi
  if bash "$PATCH_BASE/patch.sh" --install; then
    PATCH_OK=1
    log "ChatGPT-Patched.app 已生成"
  else
    log "WARN: patch.sh 执行失败，详见 $PATCH_BASE/patch.log"
  fi
else
  log "跳过副本 patch（--skip-patch）"
fi

# ---------------------------------------------------------------------------
# 10. 汇总
# ---------------------------------------------------------------------------
if [[ "$HAS_GLM" -eq 1 ]]; then
  VISION_TEXT="已启用（智谱 GLM）"
else
  VISION_TEXT="未启用：缺少 GLM key，发图片会失败；可稍后补填 $ENV_FILE 后执行 launchctl kickstart -k gui/$(id -u)/com.agent-vision-toolkit.proxy"
fi
if [[ "$SKIP_PATCH" -eq 1 ]]; then
  PATCH_TEXT="已跳过"
elif [[ "$PATCH_OK" -eq 1 ]]; then
  PATCH_TEXT="已完成（~/Applications/ChatGPT-Patched.app）"
else
  PATCH_TEXT="失败，请查看 ~/.codex/picker-patch/patch.log"
fi

SUMMARY=$'安装完成 ✅\n\n可用模型：'"$MODEL_COUNT"$' 个\n默认模型：'"$DEFAULT_MODEL"$'\n看图：'"$VISION_TEXT"$'\n双开副本：'"$PATCH_TEXT"$'\n\n下一步：\n1. 如果副本已启动，先完全退出再重新打开 Codex（生效）。\n2. 可选：gh auth login -h github.com 登录 GitHub；git config --global user.name/email 设置身份。\n3. 日志：'"$LOG"

log "$SUMMARY"
if [[ "$NONINTERACTIVE" -eq 0 ]]; then
  show_info "$SUMMARY"
fi

echo
echo "$SUMMARY"
echo
