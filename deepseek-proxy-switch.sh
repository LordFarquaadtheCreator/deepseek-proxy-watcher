#!/bin/bash
# Point DeepSeek traffic at the proxy while on known SSIDs, upstream otherwise.
# Appliers are stateful: they take true|false and write the matching value,
# they never toggle.

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
MACWIFI_CLI="/opt/homebrew/bin/macwifi-cli"
LOG="${LOG:-$HOME/Library/Logs/deepseek-proxy-switch.log}"
LOCK="${LOCK:-/tmp/deepseek-proxy-switch.lock}"
LOCK_MAX_AGE_MIN=10
LOCK_HELD=0

PROXY_SSIDS=("#Moynihan-PublicWiFi" "QPL_Wi-Fi" "Monynihan-FoodHall-Guest" "NYPL")

DEEPSEEK_PROXY_VALUE="https://deepseek.fahadfaruqi.com/"

HERMES_ENV_FILE="${HERMES_ENV_FILE:-$HOME/.hermes/.env}"
HERMES_DEEPSEEK_PROXY_KEY="DEEPSEEK_BASE_URL"
HERMES_DEEPSEEK_NO_PROXY_VALUE=""

ZED_SETTINGS="${ZED_SETTINGS:-$HOME/.config/zed/settings.json}"
ZED_DEEPSEEK_NO_PROXY_VALUE="https://api.deepseek.com/v1"

# Pre-edit copies live in the lock dir and are deleted once the edit validates.
HERMES_BAK="$LOCK/hermes.env.bak"
ZED_BAK="$LOCK/zed.settings.json.bak"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# --- lock ------------------------------------------------------------------
# mkdir is atomic. A SIGKILLed run leaks the dir, so a lock whose owner is gone
# (or is older than LOCK_MAX_AGE_MIN, which also covers pid reuse) is reclaimed.
acquire_lock() {
  local pid age

  mkdir -p "$(dirname "$LOG")" 2>/dev/null

  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    LOCK_HELD=1
    return 0
  fi

  pid=$(cat "$LOCK/pid" 2>/dev/null)
  age=$(( ( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ) / 60 ))

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$age" -lt "$LOCK_MAX_AGE_MIN" ]; then
    log "already running (pid $pid, ${age}m); exiting"
    return 1
  fi

  log "stale lock (pid ${pid:-unknown}, ${age}m); reclaiming"
  rm -f "$LOCK/pid" "$LOCK"/*.bak 2>/dev/null
  rmdir "$LOCK" 2>/dev/null

  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    LOCK_HELD=1
    return 0
  fi

  return 1
}

release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || log "lock dir not empty on release: $LOCK"
  LOCK_HELD=0
}

trap 'release_lock' EXIT INT TERM HUP

# --- ssid ------------------------------------------------------------------
get_ssid() {
  "$MACWIFI_CLI" info 2>>"$LOG" | awk '
    !seen && $1 == "SSID" { w = index($0, "BSSID") - 1; seen = 1; next }
    seen && NF {
      s = (w > 0) ? substr($0, 1, w) : $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      print s
      exit
    }'
}

is_proxy_ssid() {
  local want=$1 ss
  for ss in "${PROXY_SSIDS[@]}"; do
    [ "$ss" = "$want" ] && return 0
  done
  return 1
}

# --- helpers ---------------------------------------------------------------
_restore() { cat "$1" > "$2"; }   # keep target inode and perms

# One "<json-path>\t<value>" line per scalar leaf. Paths are emitted as JSON
# arrays so provider names containing dots or slashes stay unambiguous.
_zed_flatten() {
  jq -r 'paths(scalars) as $p | (($p | tojson) + "\t" + (getpath($p) | tojson))' "$1" | sort
}

# True only when the two documents differ in exactly one leaf: the deepseek
# api_url. Catches edits that leak into openai/x_ai/mistral/
# anthropic_compatible.*/openai_compatible.*, all of which also key on api_url.
zed_edit_is_scoped() {   # $1 before, $2 after
  local want='["language_models","deepseek","api_url"]' changed
  changed=$(diff <(_zed_flatten "$1") <(_zed_flatten "$2") 2>/dev/null \
            | grep -E '^[<>]' | cut -f1 | sed -E 's/^[<>] //' | sort -u)
  [ "$changed" = "$want" ]
}

env_validate() {   # $1 file, $2 key, $3 expected value, $4 pre-edit copy
  [ -f "$1" ] || return 1
  [ "$(grep -cE "^(export )?${2}=" "$1")" -eq 1 ] || return 1
  [ "$(sed -nE "s|^(export )?${2}=||p" "$1")" = "$3" ] || return 1
  # every other line must be untouched (-B tolerates the newline we may add)
  diff -q -B <(grep -vE "^(export )?${2}=" "$4") \
             <(grep -vE "^(export )?${2}=" "$1") >/dev/null || return 1
  return 0
}

zed_validate() {   # $1 file, $2 expected url, $3 pre-edit copy
  jq -e . "$1" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.language_models.deepseek.api_url' "$1" 2>/dev/null)" = "$2" ] || return 1
  zed_edit_is_scoped "$3" "$1" || return 1
  return 0
}

# --- appliers --------------------------------------------------------------
# Each returns 0 = written, 1 = already correct, 2 = failed (and reverted).

hermes_apply() {   # $1 true|false
  local on=$1 key="$HERMES_DEEPSEEK_PROXY_KEY" val esc tmp

  case "$on" in
    true)  val="$DEEPSEEK_PROXY_VALUE" ;;
    false) val="$HERMES_DEEPSEEK_NO_PROXY_VALUE" ;;
    *) log "hermes: bad flag '$on'"; return 2 ;;
  esac

  [ -f "$HERMES_ENV_FILE" ] || { log "hermes: $HERMES_ENV_FILE missing"; return 2; }
  mkdir -p "$LOCK" 2>/dev/null || { log "hermes: cannot create $LOCK"; return 2; }

  esc=${val//&/\\&}   # & is a replacement metachar in sed
  tmp=$(mktemp) || { log "hermes: mktemp failed"; return 2; }

  if grep -qE "^(export )?${key}=" "$HERMES_ENV_FILE"; then
    sed -E "s|^(export )?${key}=.*|\1${key}=${esc}|" "$HERMES_ENV_FILE" > "$tmp"
  elif [ -n "$(tail -c 1 "$HERMES_ENV_FILE")" ]; then
    # file lacks a trailing newline, so don't glue the new key onto the last line
    { cat "$HERMES_ENV_FILE"; echo; echo "${key}=${val}"; } > "$tmp"
  else
    { cat "$HERMES_ENV_FILE"; echo "${key}=${val}"; } > "$tmp"
  fi

  if cmp -s "$tmp" "$HERMES_ENV_FILE"; then
    rm -f "$tmp"
    return 1
  fi

  cp -p "$HERMES_ENV_FILE" "$HERMES_BAK" || { log "hermes: backup failed"; rm -f "$tmp"; return 2; }
  cat "$tmp" > "$HERMES_ENV_FILE"

  if env_validate "$HERMES_ENV_FILE" "$key" "$val" "$HERMES_BAK"; then
    rm -f "$HERMES_BAK" "$tmp"
    return 0
  fi

  _restore "$HERMES_BAK" "$HERMES_ENV_FILE"
  rm -f "$HERMES_BAK" "$tmp"
  log "hermes: post-write validation failed, reverted to pre-edit state"
  return 2
}

zed_apply() {   # $1 true|false
  local on=$1 url tmp dtype

  case "$on" in
    true)  url="$DEEPSEEK_PROXY_VALUE" ;;
    false) url="$ZED_DEEPSEEK_NO_PROXY_VALUE" ;;
    *) log "zed: bad flag '$on'"; return 2 ;;
  esac

  [ -r "$ZED_SETTINGS" ] || { log "zed: $ZED_SETTINGS unreadable"; return 2; }
  command -v jq >/dev/null || { log "zed: jq not installed"; return 2; }

  # Refuse to round-trip a file we cannot parse: Zed tolerates comments and
  # trailing commas in settings.json, jq does not.
  jq -e . "$ZED_SETTINGS" >/dev/null 2>&1 || {
    log "zed: settings.json is not strict JSON (comments?); refusing"
    return 2
  }

  dtype=$(jq -r '.language_models.deepseek | type' "$ZED_SETTINGS" 2>/dev/null)
  case "$dtype" in
    null|object) ;;
    *) log "zed: .language_models.deepseek is '$dtype'; refusing"; return 2 ;;
  esac

  mkdir -p "$LOCK" 2>/dev/null || { log "zed: cannot create $LOCK"; return 2; }
  tmp=$(mktemp) || { log "zed: mktemp failed"; return 2; }

  jq --arg u "$url" '.language_models.deepseek.api_url = $u' "$ZED_SETTINGS" > "$tmp" \
    || { log "zed: jq write failed"; rm -f "$tmp"; return 2; }

  # no-op: documents are semantically identical, so nothing to scope-check
  if diff -q <(_zed_flatten "$ZED_SETTINGS") <(_zed_flatten "$tmp") >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  if ! zed_edit_is_scoped "$ZED_SETTINGS" "$tmp"; then
    log "zed: edit would touch providers other than deepseek; refusing"
    rm -f "$tmp"
    return 2
  fi

  if cmp -s "$tmp" "$ZED_SETTINGS"; then
    rm -f "$tmp"
    return 1
  fi

  cp -p "$ZED_SETTINGS" "$ZED_BAK" || { log "zed: backup failed"; rm -f "$tmp"; return 2; }
  cat "$tmp" > "$ZED_SETTINGS"

  if zed_validate "$ZED_SETTINGS" "$url" "$ZED_BAK"; then
    rm -f "$ZED_BAK" "$tmp"
    return 0
  fi

  _restore "$ZED_BAK" "$ZED_SETTINGS"
  rm -f "$ZED_BAK" "$tmp"
  log "zed: post-write validation failed, reverted to pre-edit state"
  return 2
}

# --- main ------------------------------------------------------------------
main() {
  acquire_lock || exit 0
  sleep 3   # let DHCP/DNS settle and absorb bursts of events

  local ssid on rc=0 r
  ssid=$(get_ssid)

  case "$ssid" in
    ""|"SSID"|"<redacted>"|"-"|*"not associated"*|*"Not associated"*|*"No Wi-Fi"*)
      log "could not read SSID ('${ssid}'); leaving config unchanged"
      exit 0 ;;
  esac

  if is_proxy_ssid "$ssid"; then on=true; else on=false; fi

  hermes_apply "$on"; r=$?
  case "$r" in
    0) log "hermes -> $on (updated)" ;;
    1) log "hermes -> $on (no change)" ;;
    *) log "hermes -> $on FAILED"; rc=2 ;;
  esac

  zed_apply "$on"; r=$?
  case "$r" in
    0) log "zed -> $on (updated)" ;;
    1) log "zed -> $on (no change)" ;;
    *) log "zed -> $on FAILED"; rc=2 ;;
  esac

  log "ssid='$ssid' proxy=$on rc=$rc"
  exit $rc
}

main "$@"
