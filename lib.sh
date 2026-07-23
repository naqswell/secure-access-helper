#!/usr/bin/env bash
# Общие хелперы secure-access-helper. Этот файл ТОЛЬКО подключают (source),
# не запускают напрямую. Совместим с bash 3.2 (штатный /bin/bash на macOS),
# поэтому без declare -A, ${x,,}, mapfile и прочего из bash 4+.

# Каталог, где лежит сам репозиторий (резолвим симлинки).
SAH_SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -L "$SAH_SOURCE" ]; do
  SAH_DIR_TMP="$(cd -P "$(dirname "$SAH_SOURCE")" && pwd)"
  SAH_SOURCE="$(readlink "$SAH_SOURCE")"
  case "$SAH_SOURCE" in /*) ;; *) SAH_SOURCE="$SAH_DIR_TMP/$SAH_SOURCE" ;; esac
done
SAH_DIR="$(cd -P "$(dirname "$SAH_SOURCE")" && pwd)"

SERVICE="secure-access-helper"
APP_NAME="Citrix Secure Access"
AUTH_PROC="Citrix Secure Access auth"
# Как найти сервис Citrix в `scutil --nc list` — по bundle-id NetworkExtension,
# НЕ по хосту (репозиторий намеренно корп-агностик).
CITRIX_NC_MATCH="com.citrix.NetScalerGateway"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/secure-access-helper"
ACCOUNT_FILE="$CONFIG_DIR/account"
DESIRED_FILE="$CONFIG_DIR/desired"
PAUSE_FILE="$CONFIG_DIR/paused-until"
STATE_FILE="$CONFIG_DIR/watchdog.state"
STATUS_FILE="$CONFIG_DIR/status"
LOCK_DIR="$CONFIG_DIR/.connect.lock"

FILL_SCRIPT="$SAH_DIR/fill.applescript"
SETLAYOUT_BIN="$SAH_DIR/bin/setlayout"

AGENT_LABEL="com.nqs.secure-access-helper.watchdog"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
AGENT_PLIST_TEMPLATE="$SAH_DIR/${AGENT_LABEL}.plist.template"
WATCHDOG_LOG="$HOME/Library/Logs/secure-access-helper.watchdog.log"

# Код выхода connect.sh, когда не удалось взять lock. Это НЕ неудача коннекта —
# watchdog не должен считать её за провал (иначе backoff/notify/giveup ложно растут).
LOCK_BUSY=75

# Дефолты (env переопределяет через :-). Пользовательский конфиг подключаем НИЖЕ,
# ПОСЛЕ дефолтов и под `set +u`: битый конфиг (ссылка на unset-переменную) под
# `set -u` иначе ронял бы watchdog в crash-loop.
SAH_INTERVAL="${SAH_INTERVAL:-30}"           # период опроса, с
SAH_DEBOUNCE="${SAH_DEBOUNCE:-2}"            # подряд Disconnected до реакции
SAH_BACKOFF_BASE="${SAH_BACKOFF_BASE:-60}"   # база экспон. backoff, с
SAH_BACKOFF_MAX="${SAH_BACKOFF_MAX:-1800}"   # потолок backoff, с
SAH_NOTIFY_AFTER="${SAH_NOTIFY_AFTER:-3}"    # неудач до уведомления
SAH_GIVEUP_AFTER="${SAH_GIVEUP_AFTER:-8}"    # неудач до «сдаюсь» (sticky)
SAH_VERIFY_TIMEOUT="${SAH_VERIFY_TIMEOUT:-25}" # ждать Connected после ввода, с
SAH_OSA_MAX="${SAH_OSA_MAX:-120}"            # жёсткий потолок на один запуск osascript, с

if [ -r "$CONFIG_DIR/config" ]; then
  case $- in *u*) __sah_had_u=1 ;; *) __sah_had_u=0 ;; esac
  set +u
  . "$CONFIG_DIR/config" || true
  [ "$__sah_had_u" = 1 ] && set -u
  unset __sah_had_u
fi

sah_log() { printf '[sah] %s\n' "$*"; }
sah_err() { printf '[sah] %s\n' "$*" >&2; }

epoch() { date +%s; }

ensure_config_dir() {
  [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true
}

# ---------- аккаунт ----------

resolve_account() {
  if [ -n "${SECURE_ACCESS_ACCOUNT:-}" ]; then
    printf '%s' "$SECURE_ACCESS_ACCOUNT"; return 0
  fi
  if [ -r "$ACCOUNT_FILE" ]; then
    local acct; acct=$(head -n1 "$ACCOUNT_FILE" | tr -d '\r\n')
    [ -n "$acct" ] && { printf '%s' "$acct"; return 0; }
  fi
  local acct
  acct=$(security find-generic-password -s "$SERVICE" 2>/dev/null \
         | awk -F'"' '/^    "acct"<blob>="/ {print $4; exit}')
  [ -n "$acct" ] && { printf '%s' "$acct"; return 0; }
  return 1
}

# ---------- состояние туннеля через scutil (авторитетный сигнал) ----------

# ID сервиса Citrix в scutil (или пусто). Игнорирует Tailscale и прочие VPN.
citrix_service_id() {
  scutil --nc list 2>/dev/null | awk -v m="$CITRIX_NC_MATCH" '
    index($0, m) {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/) {
          print $i; exit
        }
    }'
}

# Печатает одно из: Connected Connecting Disconnected Disconnecting Invalid NoService Unknown
citrix_state() {
  local id; id=$(citrix_service_id)
  if [ -z "$id" ]; then echo "NoService"; return 0; fi
  local st; st=$(scutil --nc status "$id" 2>/dev/null | head -n1 | tr -d '\r')
  case "$st" in
    Connected|Connecting|Disconnected|Disconnecting|Invalid) echo "$st" ;;
    "") echo "Unknown" ;;
    *) echo "$st" ;;
  esac
}

citrix_is_up() { [ "$(citrix_state)" = "Connected" ]; }

# Чистый разрыв туннеля (auth не нужен).
citrix_stop() {
  local id; id=$(citrix_service_id)
  [ -n "$id" ] || return 1
  scutil --nc stop "$id" >/dev/null 2>&1
}

# Ждать Connected до $1 секунд (после ввода пароля scutil идёт
# Disconnected -> Connecting -> Connected).
wait_until_connected() {
  local timeout="${1:-$SAH_VERIFY_TIMEOUT}" waited=0 st
  while [ "$waited" -lt "$timeout" ]; do
    st=$(citrix_state)
    case "$st" in
      Connected) return 0 ;;
      Invalid|NoService) return 1 ;;
    esac
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

# ---------- оффлайн-гард (физический аплинк, НЕ через прокси/туннель) ----------

has_uplink() {
  local ifc
  ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
  if [ -n "$ifc" ]; then
    if ifconfig "$ifc" 2>/dev/null | grep -q 'status: active'; then return 0; fi
    if ifconfig "$ifc" 2>/dev/null | grep -q 'inet '; then return 0; fi
  fi
  local i
  for i in $(ifconfig -l 2>/dev/null); do
    case "$i" in
      en*)
        if ifconfig "$i" 2>/dev/null | grep -q 'status: active' \
           && ifconfig "$i" 2>/dev/null | grep -q 'inet '; then
          return 0
        fi ;;
    esac
  done
  return 1
}

# ---------- desired state / пауза ----------

get_desired() {
  if [ -r "$DESIRED_FILE" ]; then head -n1 "$DESIRED_FILE" | tr -d '\r\n'; else echo "up"; fi
}
set_desired() { ensure_config_dir; printf '%s\n' "$1" > "$DESIRED_FILE"; }

is_paused() {
  [ -r "$PAUSE_FILE" ] || return 1
  local until_; until_=$(head -n1 "$PAUSE_FILE" | tr -d '\r\n')
  case "$until_" in
    forever) return 0 ;;
    ''|*[!0-9]*) rm -f "$PAUSE_FILE" 2>/dev/null; return 1 ;;
    *)
      local now; now=$(epoch)
      if [ "$now" -lt "$until_" ]; then return 0; else rm -f "$PAUSE_FILE" 2>/dev/null; return 1; fi ;;
  esac
}

# ---------- lock (mkdir-атомарный; flock на macOS нет) ----------

acquire_lock() {
  local timeout="${1:-0}" waited=0 pid
  ensure_config_dir
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -r "$LOCK_DIR/pid" ]; then
      pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        # Атомарный захват устаревшего lock: rename выигрывает ровно один гонщик,
        # остальные промахиваются и снова упираются в mkdir (без double-acquire).
        if mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null; then
          rm -rf "$LOCK_DIR.stale.$$" 2>/dev/null
        fi
        continue
      fi
    fi
    if [ "$waited" -ge "$timeout" ]; then return 1; fi
    sleep 1; waited=$((waited + 1))
  done
  echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
  return 0
}
release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }

# ---------- персист backoff (переживает рестарт агента) ----------

load_state() {
  FAIL_COUNT=0; NEXT_ATTEMPT=0
  [ -r "$STATE_FILE" ] || return 0
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      fail_count) FAIL_COUNT=$val ;;
      next_attempt) NEXT_ATTEMPT=$val ;;
    esac
  done < "$STATE_FILE"
  case "$FAIL_COUNT" in ''|*[!0-9]*) FAIL_COUNT=0 ;; esac
  case "$NEXT_ATTEMPT" in ''|*[!0-9]*) NEXT_ATTEMPT=0 ;; esac
}
save_state() {
  ensure_config_dir
  { printf 'fail_count=%s\n' "$FAIL_COUNT"; printf 'next_attempt=%s\n' "$NEXT_ATTEMPT"; } > "$STATE_FILE"
}

# backoff = base * 2^(fail_count-1), но не больше max. Циклом-удвоением (bash 3.2).
compute_backoff() {
  local n="$1" b="$SAH_BACKOFF_BASE" i=1
  while [ "$i" -lt "$n" ]; do
    b=$((b * 2))
    if [ "$b" -ge "$SAH_BACKOFF_MAX" ]; then b=$SAH_BACKOFF_MAX; break; fi
    i=$((i + 1))
  done
  [ "$b" -gt "$SAH_BACKOFF_MAX" ] && b=$SAH_BACKOFF_MAX
  echo "$b"
}

# ---------- уведомления (+ status-файл, т.к. под launchd notification может молча не сработать) ----------

notify_once() {
  local key="$1" msg="$2" marker
  msg=$(printf '%s' "$msg" | tr -d '"')
  ensure_config_dir
  printf '%s\n' "$msg" > "$STATUS_FILE" 2>/dev/null || true
  sah_log "notify[$key]: $msg"
  marker="$CONFIG_DIR/.notified-$key"
  [ -e "$marker" ] && return 0
  : > "$marker" 2>/dev/null || true
  osascript -e "display notification \"$msg\" with title \"secure-access-helper\"" >/dev/null 2>&1 || true
}
clear_notify() { rm -f "$CONFIG_DIR"/.notified-* 2>/dev/null || true; }

# ---------- launchd ----------

agent_is_loaded() { launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; }
