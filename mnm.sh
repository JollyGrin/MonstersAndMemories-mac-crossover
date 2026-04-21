#!/usr/bin/env bash
#
# mnm.sh — Monsters & Memories on macOS, the hybrid way.
#
#   Mac native launcher patches the game  ->  CrossOver runs mnm.exe
#
# The Windows launcher crashes under Wine (ole32 page fault at a fixed offset
# on CrossOver 26 / wine-11.0), so we don't use it. The Mac-native Tauri app
# handles downloads and token storage; CrossOver only runs the game client.
#
# Subcommands:
#   doctor      Check env, installs, token, game files
#   mac         Download + xattr fix + re-sign + install Mac launcher
#   bottle      Create the CrossOver bottle tuned for the game (DXVK)
#   patch       Open the Mac launcher with --stinky-cheese (skips update loop)
#   play        Read token from launcher.db, run mnm.exe in the bottle
#   all         doctor + mac + bottle   (you still run patch, then play)
#   clean       Remove cached downloads (keeps bottle + installed app)
#   nuke-bottle Destroy the CrossOver bottle (interactive confirm)
#
# See LEARNINGS.md for the full investigation.

set -euo pipefail

# ---- configuration ----------------------------------------------------------
BASE_URL="https://pub-f06cad9ebbcd412bb0f4ff64f0f6a3d7.r2.dev/launcher_v2/installer"
MAC_TAR_URL="${BASE_URL}/Monsters%20%26%20Memories.app.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DL_DIR="${MNM_DL_DIR:-${SCRIPT_DIR}/dl}"
MAC_TAR="${DL_DIR}/Monsters & Memories.app.tar.gz"

APP_BUNDLE_NAME="mnm_patcher_app.app"
APP_INSTALL_DIR="${MNM_APP_DIR:-/Applications}"
APP_INSTALL_PATH="${APP_INSTALL_DIR}/${APP_BUNDLE_NAME}"
APP_BIN="${APP_INSTALL_PATH}/Contents/MacOS/mnm_launcher"

LAUNCHER_DB="${HOME}/Library/Application Support/com.monstersandmemories.mnm-patcher-app/launcher.db"

BOTTLE_NAME="${MNM_BOTTLE:-mnm}"
BOTTLE_TEMPLATE="win10_64"   # matches the community-tested recipe
BOTTLE_ROOT="${HOME}/Library/Application Support/CrossOver/Bottles/${BOTTLE_NAME}"

DEFAULT_GAME_DIR="${HOME}/Downloads/mnm"
GAME_EXE_NAME="mnm.exe"

# ---- terminal output --------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info()  { echo "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo "${C_GREEN}✓${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}!${C_RESET} $*" >&2; }
fail()  { echo "${C_RED}✗${C_RESET} $*" >&2; exit 1; }
step()  { echo; echo "${C_BOLD}${C_BLUE}▸ $*${C_RESET}"; }

# ---- helpers ----------------------------------------------------------------
detect_crossover() {
    local c
    for c in "/Applications/CrossOver.app" "${HOME}/Applications/CrossOver.app"; do
        [[ -d "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}
cx_bin() {
    local cx; cx="$(detect_crossover)" || return 1
    echo "${cx}/Contents/SharedSupport/CrossOver/bin"
}

db_get() {
    # db_get KEY -> prints value or nothing
    local key="$1"
    [[ -f "$LAUNCHER_DB" ]] || return 0
    sqlite3 "$LAUNCHER_DB" \
        "SELECT value FROM settings WHERE variable='${key//\'/\'\'}';" 2>/dev/null
}

game_dir() {
    local gp; gp="$(db_get gamePath)"
    echo "${gp:-$DEFAULT_GAME_DIR}"
}

# token_exp — echoes the `exp` unix timestamp of the stored JWT, or nothing.
# JWT is 3 base64url segments joined by "."; we decode segment 2 (payload)
# and grep for "exp":NUMBER — no jq dependency.
token_exp() {
    local tok payload pad decoded
    tok="$(db_get token)"
    [[ -n "$tok" ]] || return 0
    payload="$(awk -F. '{print $2}' <<<"$tok")"
    pad=$(( (4 - ${#payload} % 4) % 4 ))
    decoded="$(printf '%s%s' "$payload" "$(printf '=%.0s' $(seq 1 $pad 2>/dev/null))" \
              | tr '_-' '/+' | base64 -d 2>/dev/null)" || return 0
    # e.g. "...,\"exp\":1775962601,..."
    grep -oE '"exp":[0-9]+' <<<"$decoded" | head -n1 | cut -d: -f2
}

# token_status — prints "valid", "expiring N h", or "expired N d"
token_status() {
    local exp now delta days hours
    exp="$(token_exp)"
    [[ -n "$exp" ]] || { echo "no-token"; return; }
    now="$(date +%s)"
    delta=$(( exp - now ))
    if (( delta < 0 )); then
        days=$(( (-delta) / 86400 ))
        echo "expired ${days}d ago"
    elif (( delta < 3600 )); then
        echo "expiring <1h"
    elif (( delta < 86400 )); then
        hours=$(( delta / 3600 ))
        echo "expiring in ${hours}h"
    else
        days=$(( delta / 86400 ))
        echo "valid ~${days}d"
    fi
}

ensure_dl_dir() { mkdir -p "$DL_DIR"; }

download_if_missing() {
    local url="$1" out="$2" label="$3"
    if [[ -s "$out" ]]; then
        ok "${label} already downloaded ($(du -h "$out" | cut -f1))"
        return 0
    fi
    info "Downloading ${label}…"
    curl -L --fail -# -o "$out" -C - "$url"
    ok "Downloaded ${label}"
}

# ---- subcommands ------------------------------------------------------------
cmd_doctor() {
    step "Environment check"
    local arch osver cx ver
    arch="$(uname -m)"
    osver="$(sw_vers -productVersion)"
    echo "  macOS        : ${osver}"
    echo "  Architecture : ${arch}"
    [[ "$arch" == "arm64" ]] && ok "Apple Silicon detected" \
        || warn "Not Apple Silicon — DXVK will work but D3DMetal won't"

    if cx="$(detect_crossover)"; then
        ver="$(defaults read "${cx}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
        ok "CrossOver ${ver} at ${cx}"
    else
        warn "CrossOver not found — 'bottle'/'play' will fail"
    fi

    step "Install state"
    [[ -x "$APP_BIN" ]] && ok "Mac launcher installed at ${APP_INSTALL_PATH}" \
        || echo "  Mac launcher : not installed — run: ./mnm.sh mac"
    [[ -d "$BOTTLE_ROOT" ]] && ok "Bottle '${BOTTLE_NAME}' exists" \
        || echo "  Bottle       : not created — run: ./mnm.sh bottle"

    step "Game state (from launcher.db)"
    if [[ -f "$LAUNCHER_DB" ]]; then
        local user tok gp exe
        user="$(db_get username)"
        tok="$(db_get token)"
        gp="$(game_dir)"
        [[ -n "$user" ]] && ok "Logged in as ${user}" || warn "Not logged in"
        if [[ -n "$tok" ]]; then
            local status; status="$(token_status)"
            case "$status" in
                valid*)    ok "Token present — ${status}" ;;
                expiring*) warn "Token ${status} — re-login soon (./mnm.sh patch)" ;;
                expired*)  warn "Token ${status} — re-login (./mnm.sh patch) before ./mnm.sh play" ;;
                *)         ok "Token present (${#tok} chars)" ;;
            esac
        else warn "No token — open the launcher and log in"; fi
        echo "  gamePath     : ${gp}"
        exe="${gp}/${GAME_EXE_NAME}"
        if [[ -f "$exe" ]]; then ok "Game exe found: ${exe}"
        else warn "No ${GAME_EXE_NAME} in gamePath — run: ./mnm.sh patch  (then click Install)"; fi
    else
        warn "launcher.db missing — open the launcher once (./mnm.sh patch)"
    fi

    step "Downloads cached in ${DL_DIR}"
}

cmd_mac() {
    step "Installing native Mac launcher"
    ensure_dl_dir
    download_if_missing "$MAC_TAR_URL" "$MAC_TAR" "Mac launcher tar.gz"

    info "Verifying archive…"
    gzip -t "$MAC_TAR" && ok "Archive OK"

    local tmp; tmp="$(mktemp -d -t mnm-extract)"
    trap 'rm -rf "$tmp"' RETURN

    info "Extracting…"
    tar -xzf "$MAC_TAR" -C "$tmp"
    local extracted="${tmp}/${APP_BUNDLE_NAME}"
    [[ -d "$extracted" ]] || fail "Expected ${APP_BUNDLE_NAME} in archive"

    # Two-step fix: xattr -dr alone leaves _CodeSignature/CodeResources
    # missing, which codesign --verify will reject on modern macOS.
    info "Stripping com.apple.quarantine…"
    xattr -dr com.apple.quarantine "$extracted" 2>/dev/null || true
    info "Re-signing ad-hoc (regenerates _CodeSignature/CodeResources)…"
    codesign --force --deep --sign - "$extracted"
    codesign --verify --verbose=0 "$extracted" && ok "Signature valid"

    [[ -d "$APP_INSTALL_PATH" ]] && { warn "Replacing existing ${APP_INSTALL_PATH}"; rm -rf "$APP_INSTALL_PATH"; }
    info "Installing to ${APP_INSTALL_PATH}…"
    if ! mv "$extracted" "$APP_INSTALL_PATH" 2>/dev/null; then
        warn "Falling back to sudo for ${APP_INSTALL_DIR}"
        sudo mv "$extracted" "$APP_INSTALL_PATH"
    fi
    ok "Installed"
    echo
    info "Next: ${C_BOLD}./mnm.sh patch${C_RESET}  (opens the launcher with --stinky-cheese)"
}

cmd_bottle() {
    step "Creating CrossOver bottle"
    local bin; bin="$(cx_bin)" || fail "CrossOver not installed"

    if [[ -d "$BOTTLE_ROOT" ]]; then
        ok "Bottle '${BOTTLE_NAME}' already exists — leaving it alone"
        return 0
    fi

    info "Creating '${BOTTLE_NAME}' (template ${BOTTLE_TEMPLATE}, DXVK)…"
    "${bin}/cxbottle" \
        --bottle "$BOTTLE_NAME" \
        --create \
        --template "$BOTTLE_TEMPLATE" \
        --description "Monsters & Memories (game client via DXVK)" \
        --param "EnvironmentVariables:CX_GRAPHICS_BACKEND=dxvk"
    ok "Bottle created at ${BOTTLE_ROOT}"
    echo
    info "The bottle only runs the game client (${GAME_EXE_NAME}) — no Windows launcher."
}

cmd_patch() {
    [[ -x "$APP_BIN" ]] || fail "Mac launcher not installed — run: ./mnm.sh mac"
    info "Launching ${APP_INSTALL_PATH} with --stinky-cheese (skips update loop)…"
    # Run detached so this shell returns.
    nohup "$APP_BIN" --stinky-cheese >/dev/null 2>&1 &
    disown
    ok "Launcher started — log in, pick install location, Download/Patch."
    warn "${C_BOLD}Do NOT click Play${C_RESET} — that tries to exec Windows mnm.exe natively and crashes."
    warn "When patching finishes, close the launcher and run: ${C_BOLD}./mnm.sh play${C_RESET}"
}

cmd_repatch() {
    # Forces the launcher to recheck the manifest. Symptom this fixes:
    # launcher.db.game_versions says you're on a new version, but the
    # on-disk game.exe reports an older build (split-brain). "Repair"
    # in the launcher UI doesn't help because it short-circuits on the
    # version record. Deleting that row makes the next launch fetch the
    # manifest fresh and download only the changed chunks.
    [[ -f "$LAUNCHER_DB" ]] || fail "No launcher.db — run: ./mnm.sh patch first"

    if pgrep -fq "mnm_launcher"; then
        warn "Launcher is still running — close it first, then re-run this."
        exit 1
    fi

    local cur; cur="$(sqlite3 "$LAUNCHER_DB" "SELECT version FROM game_versions WHERE slug='mnm';" 2>/dev/null)"
    if [[ -n "$cur" ]]; then
        info "Clearing recorded version: ${cur}"
        sqlite3 "$LAUNCHER_DB" "DELETE FROM game_versions WHERE slug='mnm';"
        ok "Cleared. Launcher will re-diff against the live manifest on next open."
    else
        ok "No stale version record to clear."
    fi

    cmd_patch
    echo
    info "In the launcher: click Download/Patch to pull the delta. Files it already has are reused."
}

cmd_play() {
    local bin; bin="$(cx_bin)" || fail "CrossOver not installed"
    [[ -d "$BOTTLE_ROOT" ]] || fail "No bottle — run: ./mnm.sh bottle"
    [[ -f "$LAUNCHER_DB" ]] || fail "No launcher.db — run patch + log in first"

    local token gp exe
    token="$(db_get token)"
    [[ -n "$token" ]] || fail "No token in launcher.db — open the launcher and log in (./mnm.sh patch)"

    local status; status="$(token_status)"
    case "$status" in
        expired*)
            warn "Token ${status} — the game will reject it."
            warn "Refresh first: ${C_BOLD}./mnm.sh patch${C_RESET}  (launcher auto-refreshes on open)"
            fail "Aborting before a guaranteed login failure."
            ;;
        expiring\ \<1h)
            warn "Token ${status} — it may expire mid-session."
            ;;
    esac

    gp="$(game_dir)"
    exe="${gp}/${GAME_EXE_NAME}"
    [[ -f "$exe" ]] || fail "Game not downloaded — ${exe} missing. Run: ./mnm.sh patch  (then Install in the UI)"

    info "Launching ${GAME_EXE_NAME} in bottle '${BOTTLE_NAME}' (workdir: ${gp})…"
    # --workdir is important for Unity asset loading.
    # --no-wait lets this shell return while the game runs.
    "${bin}/cxstart" \
        --bottle "$BOTTLE_NAME" \
        --workdir "$gp" \
        --no-wait \
        -- "$exe" --token "$token"
    ok "Game started."
}

cmd_all() {
    cmd_doctor
    cmd_mac
    cmd_bottle
    echo
    info "Next steps:"
    echo "  1. ${C_BOLD}./mnm.sh patch${C_RESET}  (opens launcher, log in, Install/Patch)"
    echo "  2. Close the launcher once patching finishes"
    echo "  3. ${C_BOLD}./mnm.sh play${C_RESET}"
}

cmd_clean() {
    step "Removing cached downloads"
    rm -rf "$DL_DIR" "${SCRIPT_DIR}/extracted"
    ok "Done. Bottle and installed .app not touched."
}

cmd_nuke_bottle() {
    local bin; bin="$(cx_bin)" || fail "CrossOver not installed"
    [[ -d "$BOTTLE_ROOT" ]] || { ok "No bottle '${BOTTLE_NAME}' to remove"; return 0; }
    warn "This will delete the CrossOver bottle at: ${BOTTLE_ROOT}"
    read -r -p "Type the bottle name (${BOTTLE_NAME}) to confirm: " ans
    [[ "$ans" == "$BOTTLE_NAME" ]] || fail "Cancelled."
    "${bin}/cxbottle" --bottle "$BOTTLE_NAME" --delete --force
    ok "Bottle deleted."
}

# ---- dispatch ---------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}mnm.sh${C_RESET} — Monsters & Memories on macOS (Mac launcher + CrossOver game)

Usage: $0 <command>

${C_BOLD}Commands${C_RESET}
  doctor        Check env, installs, token, game files
  mac           Download + fix + install the Mac launcher
  bottle        Create the CrossOver bottle for the game client
  patch         Open the Mac launcher with --stinky-cheese (skips update loop)
  repatch       Clear the stuck version record and re-open for a forced diff
  play          Read token from launcher.db, run mnm.exe in the bottle
  all           doctor + mac + bottle  (then run patch, then play)
  clean         Remove cached downloads
  nuke-bottle   Destroy the CrossOver bottle (confirms first)

${C_BOLD}Workflow${C_RESET}
  ${C_DIM}first time:${C_RESET}    ./mnm.sh all && ./mnm.sh patch  ${C_DIM}# log in + download${C_RESET}
                                    ./mnm.sh play   ${C_DIM}# once patching is done${C_RESET}
  ${C_DIM}every launch:${C_RESET}  ./mnm.sh play
  ${C_DIM}on patch day:${C_RESET}  ./mnm.sh patch  ${C_DIM}# update, then play again${C_RESET}

${C_BOLD}Env overrides${C_RESET}
  MNM_DL_DIR     download cache             (default: ./dl)
  MNM_APP_DIR    where to install the .app  (default: /Applications)
  MNM_BOTTLE     CrossOver bottle name      (default: mnm)
EOF
}

case "${1:-}" in
    doctor)         cmd_doctor ;;
    mac)            cmd_mac ;;
    bottle)         cmd_bottle ;;
    patch)          cmd_patch ;;
    repatch)        cmd_repatch ;;
    play)           cmd_play ;;
    all)            cmd_all ;;
    clean)          cmd_clean ;;
    nuke-bottle)    cmd_nuke_bottle ;;
    -h|--help|help|"") usage ;;
    *)              usage; exit 2 ;;
esac
