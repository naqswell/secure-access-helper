#!/usr/bin/env bash
# Автоподключение VPN-клиента.
# - Аккаунт из ~/.config/secure-access-helper/account (или $SECURE_ACCESS_ACCOUNT, или Keychain)
# - Пароль — из Keychain (service=secure-access-helper)
# - Если приложение зависло (auth-окно не закрылось за HANG_TIMEOUT) — корректный quit и ретрай
set -euo pipefail

SERVICE="secure-access-helper"
APP_NAME="Citrix Secure Access"
AUTH_PROC="Citrix Secure Access auth"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/secure-access-helper"
ACCOUNT_FILE="${CONFIG_DIR}/account"
MAX_ATTEMPTS=3
HANG_TIMEOUT=30

# Резолвим симлинк (secure-access-helper в /usr/local/bin) до реального пути к скрипту
SOURCE="${BASH_SOURCE[0]:-$0}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
FILL_SCRIPT="${SCRIPT_DIR}/fill.applescript"

log() { printf '[citrix] %s\n' "$*"; }

resolve_account() {
  # Приоритет: env → конфиг-файл → парсинг Keychain (фолбэк)
  if [[ -n "${SECURE_ACCESS_ACCOUNT:-}" ]]; then
    printf '%s' "$SECURE_ACCESS_ACCOUNT"
    return 0
  fi
  if [[ -r "$ACCOUNT_FILE" ]]; then
    local acct
    acct=$(head -n1 "$ACCOUNT_FILE" | tr -d '\r\n')
    if [[ -n "$acct" ]]; then
      printf '%s' "$acct"
      return 0
    fi
  fi
  # Фолбэк: парсим вывод security — только строка вида (ровно 4 пробела) "acct"<blob>="..."
  local acct
  acct=$(security find-generic-password -s "$SERVICE" 2>/dev/null \
         | awk -F'"' '/^    "acct"<blob>="/ {print $4; exit}')
  if [[ -n "$acct" ]]; then
    printf '%s' "$acct"
    return 0
  fi
  return 1
}

quit_app() {
  # Корректный quit, без SIGKILL по подстроке (тот был опасен — задевал auth-процесс и osascript).
  log "quit ${APP_NAME}"
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  sleep 1.5
  # Если живой — SIGKILL по точному имени процесса (а не -f по подстроке)
  pkill -9 -x "${APP_NAME}" 2>/dev/null || true
  pkill -9 -x "${AUTH_PROC}" 2>/dev/null || true
  sleep 1
}

# Состояние логин-флоу.
# "loginVisible" — auth-форма или auth-окно ещё видно
# "gone"         — auth-окна нет (логин завершён или не начат)
# "noProcess"    — процесса целевого приложения нет
login_window_state() {
  osascript <<OSA 2>/dev/null || echo "noProcess"
tell application "System Events"
    try
        if exists process "${AUTH_PROC}" then
            tell process "${AUTH_PROC}"
                if (count of windows) > 0 then return "loginVisible"
            end tell
        end if
    end try
    if not (exists process "${APP_NAME}") then return "noProcess"
    tell process "${APP_NAME}"
        if (count of windows) = 0 then return "gone"
        repeat with w in windows
            try
                if (title of w) as string contains "auth" then return "loginVisible"
            end try
        end repeat
        return "gone"
    end tell
end tell
OSA
}

ACCOUNT="$(resolve_account || true)"
if [[ -z "${ACCOUNT}" ]]; then
  echo "Не нашёл аккаунт. Запусти: ${SCRIPT_DIR}/setup.sh" >&2
  echo "Или задай переменную SECURE_ACCESS_ACCOUNT=<логин>." >&2
  exit 1
fi
log "аккаунт: ${ACCOUNT}"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  log "попытка ${attempt}/${MAX_ATTEMPTS}"

  raw_result=$(osascript "$FILL_SCRIPT" "$ACCOUNT" 2>&1 || true)
  # AppleScript может выплюнуть warning'и в stderr перед `return` — берём только последнюю
  # непустую строку, она и есть финальный return.
  result=$(printf '%s\n' "$raw_result" | awk 'NF{last=$0} END{print last}')
  log "fill: ${result}"

  case "$result" in
    "alreadyConnected")
      log "Уже подключён"
      exit 0
      ;;
    "windowNotAppeared")
      log "окно приложения не появилось — считаем, что приложение в фоне/подключено"
      exit 0
      ;;
    "ok")
      ;;
    ERROR:*)
      # Некоторые ошибки бессмысленно ретраить — выходим сразу
      case "$result" in
        *"не настроено ни одного подключения"*\
        |*"frontmost"*\
        |*"keychain access failed"*\
        |*"не найдено ни Connect, ни Disconnect"*)
          err_msg="${result#ERROR: }"
          echo
          echo "Не могу подключиться: ${err_msg}" >&2
          exit 1
          ;;
      esac
      log "ошибка при заполнении: ${result}"
      quit_app
      continue
      ;;
    *)
      log "неожиданный ответ AppleScript, retry"
      quit_app
      continue
      ;;
  esac

  # Ждём, пока логин-флоу завершится (auth-окно исчезнет)
  waited=0
  while (( waited < HANG_TIMEOUT )); do
    sleep 1
    waited=$(( waited + 1 ))
    state=$(login_window_state)
    if [[ "$state" == "gone" ]]; then
      log "подключение пошло (auth-окно закрылось за ${waited}с)"
      exit 0
    fi
    if [[ "$state" == "noProcess" ]]; then
      log "процесс приложения пропал — retry"
      break
    fi
  done

  log "завис: auth-окно ещё на экране через ${HANG_TIMEOUT}с"
  quit_app
done

echo "Не удалось подключиться за ${MAX_ATTEMPTS} попыток" >&2
exit 1
