#!/bin/bash
set -euo pipefail

SOURCE="/Applications/ChatGPT.app"
PATCHED="$HOME/Applications/ChatGPT-Patched.app"
BASE="$HOME/.codex/picker-patch"
MARKER="$BASE/patch-state.json"
LOG="$BASE/patch.log"
AGENT_LABEL="com.steve233.codex-picker-patch"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
CODEX_HOME_DIR="$HOME/.codex-deepseek"

# Self-signed code signing identity (Plan B): stable TCC authorization across
# rebuilds. Keychain lives at ~/Library/Keychains/codex-signing.keychain-db.
SIGN_IDENTITY="Codex Patched Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/codex-signing.keychain-db"
SIGN_KEYCHAIN_PASS="0000"

# 26.810+: model visibility filter was rewritten. Old pattern was
# 'i&&t!==`amazonBedrock`' (26.803-); new code is
# n.filter(e=>i.useHiddenModels&&r!==`amazonBedrock`?i.availableModels.has(e.model):!e.hidden)
# Patch flips `!==` -> `===` so the non-Bedrock filter path is skipped and
# custom (DeepSeek) models are never filtered out by availableModels.
PATTERN='i.useHiddenModels&&r!==`amazonBedrock`'
PATCH_FROM='!=='
PATCH_TO='==='
SILENT=0

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  mkdir -p "$BASE"
  echo "$msg" >> "$LOG"
  if [ "$SILENT" -ne 1 ]; then echo "$msg"; fi
}

resolve_source() {
  if [ -d "$SOURCE" ] && [ -f "$SOURCE/Contents/Info.plist" ]; then
    echo "$SOURCE"
  elif [ -d "$HOME/Applications/ChatGPT.app" ] && [ -f "$HOME/Applications/ChatGPT.app/Contents/Info.plist" ]; then
    echo "$HOME/Applications/ChatGPT.app"
  else
    echo "$SOURCE"
  fi
}

app_version() {
  local src
  src=$(resolve_source)
  local plist="$src/Contents/Info.plist"
  if [ ! -f "$plist" ]; then echo "unknown"; return; fi
  # PlistBuddy prints "File Doesn't Exist, Will Create..." to stdout on missing file,
  # so pre-check existence and silence both stdout/stderr on error paths
  local v
  v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null) || v="unknown"
  # filter out PlistBuddy's creation message if it leaked
  if [[ "$v" == *"Will Create"* ]] || [[ "$v" == *"Does Not Exist"* ]]; then echo "unknown"; else echo "$v"; fi
}

patched_running() {
  pgrep -f "$PATCHED/Contents/MacOS" >/dev/null 2>&1
}

get_marker_version() {
  if [ -f "$MARKER" ]; then
    sed -nE 's/.*"sourceVersion": *"([^"]*)".*/\1/p' "$MARKER" 2>/dev/null | head -1 || true
  fi
}

is_patched() {
  local asar="$PATCHED/Contents/Resources/app.asar"
  [ -f "$asar" ] || return 1
  grep -aqE 'i\.useHiddenModels&&r===`amazonBedrock`' "$asar" 2>/dev/null
}

build_patched() {
  log "== build patched copy =="
  # Resolve actual source location (handles /Applications vs ~/Applications installs)
  local actual_source
  actual_source=$(resolve_source)
  if [ "$actual_source" != "$SOURCE" ]; then
    log "source resolved to $actual_source (canonical $SOURCE missing)"
    SOURCE="$actual_source"
  fi
  local version
  version=$(app_version)
  log "source version: $version"

  if [ "$version" = "unknown" ] || [ ! -d "$SOURCE" ]; then
    log "ERROR: cannot read source app"
    exit 1
  fi

  if patched_running; then
    log "ERROR: patched copy is running, cannot rebuild"
    exit 1
  fi

  # Safety: never touch CODEX_HOME. Only the patched app bundle is rebuilt.
  case "$PATCHED" in
    "$CODEX_HOME_DIR"|"$CODEX_HOME_DIR"/*|"$(dirname "$PATCHED")")
      log "FATAL: PATCHED path collides with CODEX_HOME, refusing"
      exit 1 ;;
  esac

  # Rebuild the patched copy from the current (possibly updated) source.
  rm -rf "$PATCHED"
  mkdir -p "$(dirname "$PATCHED")"
  cp -R "$SOURCE" "$PATCHED"
  log "copied source -> $PATCHED"

  local asar="$PATCHED/Contents/Resources/app.asar"
  local plist="$PATCHED/Contents/Info.plist"

  # Unique-occurrence check: abort if the pattern moved (upstream rebuild).
  local matches off
  matches=$(grep -aboE "$PATTERN" "$asar" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$matches" -ne 1 ]; then
    log "ERROR: pattern occurrences=$matches (expected 1), refusing to patch. App may have a code change."
    rm -rf "$PATCHED"
    exit 1
  fi
  off=$(grep -aboE "$PATTERN" "$asar" 2>/dev/null | head -1 | cut -d: -f1)
  # PATTERN itself contains the '!==' we need to flip; compute its offset
  # within PATTERN and add it to the asar offset of PATTERN.
  local within
  within=$(printf '%s' "$PATTERN" | grep -aboF "$PATCH_FROM" | head -1 | cut -d: -f1)
  off=$((off + within))
  printf '%s' "$PATCH_TO" | dd of="$asar" bs=1 seek="$off" count="${#PATCH_TO}" conv=notrunc 2>/dev/null

  if ! is_patched; then
    log "ERROR: patch byte verification failed, removing broken copy"
    rm -rf "$PATCHED"
    exit 1
  fi
  log "pattern '$PATTERN' patched ($PATCH_FROM -> $PATCH_TO) at offset $off"

  # Disable Sparkle updates in the patched copy: replace the feed URL with a
  # same-length RFC-2606 reserved host (always fails DNS) so the in-app
  # "Check for Updates" action can never download a fresh official bundle.
  local feed_old='https://persistent.oaistatic.com/codex-app-prod/appcast.xml'
  local feed_new='https://invalid.invalid.invalid/codex-app-prod/appcast.xml'
  local feed_matches
  feed_matches=$(grep -aboF "$feed_old" "$asar" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$feed_matches" -eq 1 ]; then
    local feed_off
    feed_off=$(grep -aboF "$feed_old" "$asar" 2>/dev/null | head -1 | cut -d: -f1)
    printf '%s' "$feed_new" | dd of="$asar" bs=1 seek="$feed_off" count=${#feed_old} conv=notrunc 2>/dev/null
    log "sparkle feed URL disabled (offset $feed_off)"
  elif [ "$feed_matches" -eq 0 ]; then
    log "WARN: sparkle feed URL not found (code change?), skipping"
  else
    log "ERROR: sparkle feed URL occurrences=$feed_matches (expected 1), refusing"
    rm -rf "$PATCHED"
    exit 1
  fi

  # Inject CODEX_HOME so the patched copy uses the isolated data directory.
  if ! /usr/libexec/PlistBuddy -c "Print :LSEnvironment" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist"
  fi
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CODEX_HOME '$CODEX_HOME_DIR'" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CODEX_HOME string '$CODEX_HOME_DIR'" "$plist"
  log "LSEnvironment CODEX_HOME -> $CODEX_HOME_DIR"

  # Unique bundle id so the official app and the patched copy can run side by side.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.steve233.codex-patched" "$plist"
  log "CFBundleIdentifier -> com.steve233.codex-patched"

  # Disable Sparkle's automatic update checks for the patched copy.
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$plist"
  log "SUEnableAutomaticChecks -> false"

  # Separate Chromium userData: wrap the main executable in a tiny Mach-O
  # launcher that injects --user-data-dir=~/Library/Application Support/Codex-Patched.
  # (launchd refuses shell scripts as the main executable; CHROME_USER_DATA_DIR
  # is ignored by Electron, and a space-separated --user-data-dir arg is not
  # forwarded to child processes — use the '=' form.)
  local bindir="$PATCHED/Contents/MacOS"
  mv "$bindir/ChatGPT" "$bindir/ChatGPT.bin"
  local uddir="$HOME/Library/Application Support/Codex-Patched"
  cat > "$BASE/scripts/launcher.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char *home = getenv("HOME");
    if (!home) home = "/Users/steve233";
    char ud[1100];
    snprintf(ud, sizeof(ud), "--user-data-dir=%s/Library/Application Support/Codex-Patched", home);
    char *bin = "/Users/steve233/Applications/ChatGPT-Patched.app/Contents/MacOS/ChatGPT.bin";
    int n = argc + 1;
    char **newargv = malloc(sizeof(char*) * (n + 1));
    newargv[0] = bin;
    newargv[1] = ud;
    for (int i = 1; i < argc; i++) newargv[i + 1] = argv[i];
    newargv[n] = NULL;
    execv(bin, newargv);
    perror("execv");
    return 1;
}
EOF
  clang -O2 -o "$bindir/ChatGPT" "$BASE/scripts/launcher.c" >> "$LOG" 2>&1
  log "main executable wrapped with user-data-dir launcher ($uddir)"

  # Newer builds verify the asar header hash stored in Info.plist. Since the
  # patch is a same-length byte edit, the header hash is unchanged; the
  # signature still needs refreshing because the asar content changed.
  # Plan B: sign with a self-signed cert (stable TCC identity across rebuilds)
  # instead of ad-hoc (adhoc binds TCC grants to the CDHash, which breaks on
  # every rebuild -> screen recording/accessibility permissions are lost).
  security unlock-keychain -p "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN" >> "$LOG" 2>&1 || true
  log "re-signing with cert ($SIGN_IDENTITY)..."
  # Use the stable entitlements file (application-groups + automation etc.)
  # so CUAService bootstrap and appshot work after every rebuild.
  if codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" --entitlements "$BASE/certs/ent2.plist" "$PATCHED" >> "$LOG" 2>&1; then
    log "re-signed"
  else
    log "ERROR: cert signing failed (is the keychain unlocked?), falling back to ad-hoc"
    codesign --force --deep --sign - "$PATCHED" >> "$LOG" 2>&1
    log "re-signed (ad-hoc fallback)"
  fi

  printf '{"sourceVersion":"%s","builtAt":"%s"}\n' "$version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
  log "marker written: $version"
}

install() {
  if ! is_patched; then
    build_patched
  else
    log "already patched (version $(get_marker_version)), skip"
  fi
  log "launching patched copy..."
  open "$PATCHED"
  log "launched $PATCHED"
}

auto_update() {
  SILENT=1
  local current marker_ver
  current=$(app_version)
  marker_ver=$(get_marker_version)

  if [ -z "$current" ] || [ "$current" = "unknown" ]; then
    log "auto-update: cannot read source version, skip"
    exit 0
  fi
  if [ "$current" = "$marker_ver" ] && is_patched; then
    log "auto-update: up to date ($current), no action"
    exit 0
  fi
  if patched_running; then
    log "auto-update: update available ($current vs $marker_ver) but patched copy running, defer"
    exit 0
  fi
  log "auto-update: version changed ($marker_ver -> $current), rebuilding"
  if build_patched; then
    log "auto-update: rebuilt successfully at $current"
  else
    log "auto-update: rebuild FAILED, source app untouched"
    exit 1
  fi
}

uninstall() {
  log "== uninstall =="
  if patched_running; then
    log "patched copy running, killing..."
    pkill -f "$PATCHED/Contents/MacOS" 2>/dev/null || true
    sleep 1
  fi
  if [ -d "$PATCHED" ]; then
    rm -rf "$PATCHED"
    log "removed $PATCHED (official app in /Applications untouched)"
  fi
  rm -f "$MARKER"
  if [ -f "$AGENT_PLIST" ]; then
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
    log "launchd agent removed"
  fi
}

status() {
  local src src_ver patched_ver
  src=$(resolve_source)
  src_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$src/Contents/Info.plist" 2>/dev/null || echo "unknown")
  if [[ "$src_ver" == *"Will Create"* ]] || [[ "$src_ver" == *"Does Not Exist"* ]]; then src_ver="unknown"; fi
  if [ -d "$PATCHED" ]; then
    patched_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PATCHED/Contents/Info.plist" 2>/dev/null || echo "unknown")
    if [[ "$patched_ver" == *"Will Create"* ]]; then patched_ver="unknown"; fi
    echo "source:        $src ($src_ver)"
    echo "patched copy:  $PATCHED ($patched_ver) ($(is_patched && echo patched || echo unpatched))"
  else
    echo "source:        $src ($src_ver)"
    echo "patched copy:  not built"
  fi
  echo "marker:        $(get_marker_version)"
  echo "agent:         $([ -f "$AGENT_PLIST" ] && echo "plist installed" || echo "not installed")"
}

case "${1:-}" in
  --install)   install ;;
  --auto-update) auto_update ;;
  --uninstall) uninstall ;;
  --status)    status ;;
  *) echo "usage: $0 {--install|--auto-update|--uninstall|--status}"; exit 1 ;;
esac