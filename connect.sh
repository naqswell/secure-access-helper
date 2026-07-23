#!/usr/bin/env bash
# secure-access-helper — CLI. Подкоманды: connect (по умолчанию), status, off,
# pause, resume, watch, doctor, install-agent, uninstall-agent.
#
# Ключевое отличие от «нажать Connect в UI»: успех подтверждается АВТОРИТЕТНО через
# `scutil --nc status` (Connected), а не по тому, закрылось ли auth-окно. Пароль —
# из Keychain; аккаунт — из ~/.config/secure-access-helper/account (или env, или Keychain).
set -uo pipefail

SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$DIR/$SOURCE" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

quit_app() {
  sah_log "quit $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  sleep 1.5
  pkill -9 -x "$APP_NAME" 2>/dev/null || true
  pkill -9 -x "$AUTH_PROC" 2>/dev/null || true
  sleep 1
}

# Запуск fill.applescript с ЖЁСТКИМ потолком по времени: зависший WebView/AX не
# должен подвесить osascript (а через watchdog — весь цикл) на минуты. Печатает
# вывод fill; возвращает 124, если пришлось убить по таймауту.
run_fill() {
  local acct="$1" dir="$2" out opid waited=0 killed=0
  out=$(mktemp 2>/dev/null) || out="${TMPDIR:-/tmp}/sah_fill.$$"
  osascript "$FILL_SCRIPT" "$acct" "$dir" >"$out" 2>&1 &
  opid=$!
  while kill -0 "$opid" 2>/dev/null; do
    if [ "$waited" -ge "$SAH_OSA_MAX" ]; then
      kill -TERM "$opid" 2>/dev/null; sleep 1; kill -KILL "$opid" 2>/dev/null; killed=1; break
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$opid" 2>/dev/null
  cat "$out" 2>/dev/null; rm -f "$out" 2>/dev/null
  [ "$killed" = 1 ] && return 124
  return 0
}

cmd_connect() {
  # desired=up ставим ТОЛЬКО из интерактивного вызова. Из watchdog (SAH_WATCHDOG=1)
  # НЕ трогаем desired — иначе авто-реконнект затрёт только что сделанный `off`.
  [ -n "${SAH_WATCHDOG:-}" ] || set_desired up

  # Fast-path: если scutil уже говорит Connected — не трогаем UI (ни фокус, ни Keychain).
  local st; st=$(citrix_state)
  case "$st" in
    Connected)
      sah_log "уже подключён"; clear_notify; return 0 ;;
    Connecting)
      sah_log "идёт подключение — жду"
      if wait_until_connected "$SAH_VERIFY_TIMEOUT"; then sah_log "подключено"; clear_notify; return 0; fi ;;
  esac

  local account; account=$(resolve_account || true)
  if [ -z "$account" ]; then
    sah_err "Не нашёл аккаунт. Запусти: $SCRIPT_DIR/setup.sh (или задай SECURE_ACCESS_ACCOUNT)."
    return 1
  fi
  sah_log "аккаунт: $account"

  if ! acquire_lock 3; then
    sah_err "Уже выполняется другое подключение (lock). Пропуск."
    return "$LOCK_BUSY"
  fi
  trap 'release_lock' EXIT

  local attempt raw result rc
  for attempt in 1 2 3; do
    # Уважать `off`, прилетевший уже во время коннекта. Возвращаем LOCK_BUSY (а не 0):
    # это не успех реконнекта, watchdog должен трактовать как no-op, без «переподключено».
    if [ "$(get_desired)" = "down" ]; then
      sah_log "desired=down во время коннекта — прерываю."
      return "$LOCK_BUSY"
    fi
    sah_log "попытка $attempt/3"
    raw=$(run_fill "$account" "$SCRIPT_DIR"); rc=$?
    # AppleScript может писать warning'и в stderr перед финальным return —
    # берём последнюю непустую строку.
    result=$(printf '%s\n' "$raw" | awk 'NF{last=$0} END{print last}')
    if [ "$rc" -eq 124 ]; then
      sah_log "fill: убит по таймауту (${SAH_OSA_MAX}s) — retry"
      quit_app; continue
    fi
    sah_log "fill: $result"

    case "$result" in
      ERROR:*)
        # frontmost/фокус НЕ в списке фатальных: это транзиентно и дёшево ретраится
        # (quit_app + попытка 2/3); ложный успех отсечёт wait_until_connected по scutil.
        case "$result" in
          *"не настроено ни одного подключения"*|*"keychain access failed"*|*"не найдено ни Connect, ни Disconnect"*|*"нелатинская раскладка"*)
            sah_err "Не могу подключиться: ${result#ERROR: }"
            return 1 ;;
        esac
        sah_log "ошибка при заполнении — retry"
        quit_app; continue ;;
    esac

    # Авторитетная проверка: реально ли встал туннель. НЕ доверяем "ok" от UI.
    if wait_until_connected "$SAH_VERIFY_TIMEOUT"; then
      # `off` мог прилететь во время fill — тогда откатываем туннель, а не рапортуем успех.
      if [ "$(get_desired)" = "down" ]; then
        sah_log "desired=down во время коннекта — откатываю туннель."
        citrix_stop
        return "$LOCK_BUSY"
      fi
      sah_log "подключено (scutil: Connected)"
      clear_notify
      return 0
    fi

    st=$(citrix_state)
    sah_log "туннель не поднялся (scutil: $st) — retry"
    quit_app
  done

  sah_err "Не удалось подключиться за 3 попытки (scutil так и не показал Connected)."
  return 1
}

cmd_off() {
  set_desired down
  if citrix_stop; then
    sah_log "отключение отправлено (scutil stop). desired=down — авто-реконнект выключен."
  else
    sah_err "не нашёл сервис Citrix для остановки (но desired=down выставлен)."
  fi
}

cmd_status() {
  local st id desired paused
  id=$(citrix_service_id)
  st=$(citrix_state)
  desired=$(get_desired)
  if is_paused; then paused="да ($(head -n1 "$PAUSE_FILE" 2>/dev/null))"; else paused="нет"; fi
  echo "Туннель (scutil):   $st"
  echo "Сервис ID:          ${id:-<не найден>}"
  echo "Желаемое (desired): $desired"
  echo "Watchdog пауза:     $paused"
  if agent_is_loaded; then echo "Агент watchdog:     загружен"; else echo "Агент watchdog:     не загружен"; fi
  load_state
  local na="-"; [ "$NEXT_ATTEMPT" != 0 ] && na=$(date -r "$NEXT_ATTEMPT" '+%H:%M:%S' 2>/dev/null)
  echo "Backoff:            fail_count=$FAIL_COUNT next_attempt=$na"
  [ -r "$STATUS_FILE" ] && echo "Последний статус:   $(head -n1 "$STATUS_FILE")"
  if [ -r "$WATCHDOG_LOG" ]; then
    echo "--- хвост watchdog-лога ---"
    tail -n 6 "$WATCHDOG_LOG"
  fi
}

parse_duration() {
  local d="$1" n unit
  case "$d" in
    *[0-9]s) n=${d%s}; unit=s ;;
    *[0-9]m) n=${d%m}; unit=m ;;
    *[0-9]h) n=${d%h}; unit=h ;;
    *[0-9])  n=$d;     unit=s ;;
    *) return 1 ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
  esac
}

cmd_pause() {
  local dur="$1" secs until_
  ensure_config_dir
  if [ -z "$dur" ]; then
    printf 'forever\n' > "$PAUSE_FILE"
    sah_log "watchdog на паузе до 'resume'."
    return 0
  fi
  secs=$(parse_duration "$dur") || { sah_err "не понял длительность '$dur' (примеры: 30m, 2h, 90s)"; return 1; }
  until_=$(( $(epoch) + secs ))
  printf '%s\n' "$until_" > "$PAUSE_FILE"
  sah_log "watchdog на паузе ${secs}s (до $(date -r "$until_" '+%H:%M:%S' 2>/dev/null))."
}

cmd_resume() { rm -f "$PAUSE_FILE" 2>/dev/null; sah_log "watchdog снят с паузы."; }

cmd_doctor() {
  local ok=1 acct axout
  echo "== secure-access-helper doctor =="
  if command -v scutil >/dev/null 2>&1; then echo "[ok] scutil есть"; else echo "[!!] нет scutil"; ok=0; fi
  local id; id=$(citrix_service_id)
  if [ -n "$id" ]; then echo "[ok] сервис Citrix: $id ($(citrix_state))"; else echo "[!!] сервис Citrix не найден (scutil --nc list)"; ok=0; fi
  if [ -d "/Applications/$APP_NAME.app" ]; then echo "[ok] приложение установлено"; else echo "[!!] нет /Applications/$APP_NAME.app"; ok=0; fi
  acct=$(resolve_account || true)
  if [ -n "$acct" ]; then echo "[ok] аккаунт: $acct"; else echo "[!!] аккаунт не настроен (setup.sh)"; ok=0; fi
  if [ -n "$acct" ] && security find-generic-password -a "$acct" -s "$SERVICE" -w >/dev/null 2>&1; then
    echo "[ok] пароль читается из Keychain"
  else
    echo "[!!] пароль из Keychain не читается (setup.sh / 'Always Allow')"; ok=0
  fi
  axout=$(osascript -e 'tell application "System Events" to keystroke ""' 2>&1) || true
  case "$axout" in
    *"-25211"*|*"not allowed assistive access"*) echo "[!!] нет Accessibility у текущего контекста"; ok=0 ;;
    *) echo "[ok] Accessibility: печатать можно (для текущего процесса)" ;;
  esac
  if [ -x "$SETLAYOUT_BIN" ]; then echo "[ok] setlayout собран (текущая раскладка: $("$SETLAYOUT_BIN" 2>/dev/null))"; else echo "[..] setlayout не собран — будет fallback (clipboard/keystroke)"; fi
  if agent_is_loaded; then echo "[ok] агент watchdog загружен"; else echo "[..] агент watchdog не загружен (install-agent)"; fi
  if has_uplink; then echo "[ok] аплинк есть"; else echo "[..] аплинк не найден (оффлайн?)"; fi
  echo "================================"
  [ "$ok" -eq 1 ]
}

cmd_install_agent() {
  ensure_config_dir
  if [ ! -r "$AGENT_PLIST_TEMPLATE" ]; then sah_err "нет шаблона: $AGENT_PLIST_TEMPLATE"; return 1; fi
  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$WATCHDOG_LOG")"
  # Зашиваем в plist РЕЗОЛВНУТЫЙ конфиг-каталог: launchd не наследует env шелла,
  # иначе агент читал бы desired/pause/state из $HOME/.config, а CLI — из XDG-пути.
  local xdg; xdg="${XDG_CONFIG_HOME:-$HOME/.config}"
  sed -e "s|@REPO@|$SCRIPT_DIR|g" -e "s|@HOME@|$HOME|g" -e "s|@XDG@|$xdg|g" \
    "$AGENT_PLIST_TEMPLATE" > "$AGENT_PLIST"
  local uid; uid=$(id -u)
  # bootout асинхронный — ждём фактической выгрузки, иначе bootstrap ловит гонку.
  launchctl bootout "gui/$uid/$AGENT_LABEL" >/dev/null 2>&1 || true
  local w=0
  while agent_is_loaded && [ "$w" -lt 5 ]; do sleep 1; w=$((w + 1)); done
  if launchctl bootstrap "gui/$uid" "$AGENT_PLIST" 2>/dev/null || agent_is_loaded; then
    sah_log "агент загружен: $AGENT_LABEL"
  else
    launchctl unload "$AGENT_PLIST" >/dev/null 2>&1 || true
    if launchctl load -w "$AGENT_PLIST" 2>/dev/null || agent_is_loaded; then
      sah_log "агент загружен (load -w): $AGENT_LABEL"
    else
      sah_err "не удалось загрузить агент через launchctl"; return 1
    fi
  fi
  [ -n "${SAH_WATCHDOG:-}" ] || set_desired up
  cat <<EOF

Готово. Агент держит VPN поднятым и переподключает при обрыве.

ВАЖНО — ограничения фонового агента:
  1) Accessibility. launchd запускает osascript в СВОЁМ TCC-контексте (не терминала),
     и macOS НЕ покажет попап фоновому агенту. Первый авто-реконнект просто молча не
     кликнет/не напечатает, ПОКА не выдашь грант вручную:
       Системные настройки → Конфиденциальность и безопасность → Универсальный доступ
       → включи пункт для агента (может называться 'bash' или 'osascript').
     На свежих macOS такой пункт для голого /bin/bash иногда не появляется/не
     «прилипает» — тогда авто-реконнект работать не будет (ограничение TCC).
  2) Только в разблокированной GUI-сессии. На экране логина/при заблокированном
     Keychain реконнект не пройдёт (нет доступа к паролю и к UI).
  3) 'doctor' проверяет Accessibility в контексте ТЕРМИНАЛА, не агента — его «ok»
     не гарантирует грант агенту. Реальная проверка — живой обрыв + лог.
  Лог: $WATCHDOG_LOG
EOF
}

cmd_uninstall_agent() {
  local uid; uid=$(id -u)
  launchctl bootout "gui/$uid/$AGENT_LABEL" >/dev/null 2>&1 \
    || launchctl unload "$AGENT_PLIST" >/dev/null 2>&1 || true
  if [ -e "$AGENT_PLIST" ]; then
    rm -f "$AGENT_PLIST" 2>/dev/null && sah_log "агент выгружен, plist удалён."
  else
    sah_log "агент не был установлен."
  fi
}

usage() {
  cat <<EOF
secure-access-helper — автоподключение Citrix VPN + watchdog авто-реконнекта.

  secure-access-helper [connect]       подключиться (по умолчанию)
  secure-access-helper status          состояние туннеля / агента / backoff
  secure-access-helper off             отключить и запретить авто-реконнект (desired=down)
  secure-access-helper pause [Nm|Nh]   пауза watchdog (без аргумента — до resume)
  secure-access-helper resume          снять паузу
  secure-access-helper watch           цикл watchdog (обычно запускает launchd)
  secure-access-helper doctor          диагностика окружения
  secure-access-helper install-agent   установить + загрузить launchd-агент
  secure-access-helper uninstall-agent выгрузить + удалить агент
EOF
}

main() {
  local cmd="${1:-connect}"
  case "$cmd" in
    connect|"") cmd_connect ;;
    status) cmd_status ;;
    off|disconnect) cmd_off ;;
    pause) shift; cmd_pause "${1:-}" ;;
    resume) cmd_resume ;;
    watch) exec "$SCRIPT_DIR/watchdog.sh" ;;
    doctor) cmd_doctor ;;
    install-agent) cmd_install_agent ;;
    uninstall-agent) cmd_uninstall_agent ;;
    -h|--help|help) usage ;;
    *) sah_err "неизвестная команда: $cmd"; usage; exit 2 ;;
  esac
}

main "$@"
