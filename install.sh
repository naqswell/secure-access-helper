#!/usr/bin/env bash
# Установка secure-access-helper на macOS.
# Идемпотентный: при повторном запуске пропускает уже выполненные шаги
# или предлагает их пересоздать.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="/Applications/Citrix Secure Access.app"
SERVICE="secure-access-helper"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/secure-access-helper"
ACCOUNT_FILE="${CONFIG_DIR}/account"

# Возможные локации для симлинка (порядок — приоритет)
SYMLINK_NAME="secure-access-helper"
SYMLINK_CANDIDATES=(
  "/opt/homebrew/bin/${SYMLINK_NAME}"   # Apple Silicon Homebrew (часто writable без sudo)
  "/usr/local/bin/${SYMLINK_NAME}"      # классика
)

# ---------- helpers ----------

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Понятное сообщение при необработанной ошибке
trap 'rc=$?; err "Установка прервана на строке $LINENO (exit=$rc)."; exit $rc' ERR

ask_yn() {
  # ask_yn "<вопрос>" <default Y|N>
  local prompt="$1" default="${2:-Y}"
  local hint="[Y/n]"; [[ "$default" == "N" ]] && hint="[y/N]"
  local ans
  read -rp "$prompt $hint " ans || ans=""
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Имя «текущего терминала» — поднимаемся по дереву процессов и ищем app-bandle
detect_terminal_app() {
  local pid=$PPID hops=0 comm
  while (( hops < 6 )); do
    [[ -z "$pid" || "$pid" == "0" || "$pid" == "1" ]] && break
    comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    case "$comm" in
      */Applications/*.app/Contents/MacOS/*|*/System/Applications/*.app/Contents/MacOS/*|*/System/Library/CoreServices/*.app/Contents/MacOS/*)
        # /Applications/Warp.app/Contents/MacOS/stable → Warp
        printf '%s' "$comm" | sed -E 's|.*/([^/]+)\.app/.*|\1|'
        return 0
        ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
    ((hops++))
  done
  return 1
}

accessibility_ok() {
  # Если нет AX-прав — `keystroke ""` ловит -25211 / "not allowed assistive access"
  local out
  out=$(osascript -e 'tell application "System Events" to keystroke ""' 2>&1) || true
  if [[ "$out" == *"-25211"* || "$out" == *"not allowed assistive access"* ]]; then
    return 1
  fi
  return 0
}

# ---------- step 1: целевое приложение ----------

bold "==> Проверка целевого приложения"
if [[ ! -d "$APP_PATH" ]]; then
  err "Целевое приложение не найдено в /Applications."
  err "Установи его и запусти install.sh заново."
  exit 1
fi
note "OK: ${APP_PATH}"

# ---------- step 2: chmod ----------

bold "==> chmod +x"
chmod +x "${SCRIPT_DIR}/setup.sh" "${SCRIPT_DIR}/connect.sh" "${SCRIPT_DIR}/uninstall.sh" "${SCRIPT_DIR}/citrix-vpn-watchdog" 2>/dev/null || true
note "OK"

# ---------- step 2b: хелпер раскладки (setlayout) ----------
bold "==> Хелпер раскладки (setlayout)"
if command -v swiftc >/dev/null 2>&1; then
  mkdir -p "${SCRIPT_DIR}/bin"
  SWIFT_ERR=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/sah_swiftc_err.$$")
  if swiftc -O "${SCRIPT_DIR}/setlayout.swift" -o "${SCRIPT_DIR}/bin/setlayout" 2>"$SWIFT_ERR"; then
    note "OK: собран ${SCRIPT_DIR}/bin/setlayout"
  else
    warn "swiftc не смог собрать setlayout:"
    cat "$SWIFT_ERR" >&2 || true
    warn "Не критично: пароль будет вводиться через clipboard-paste (fallback)."
  fi
  rm -f "$SWIFT_ERR"
else
  warn "swiftc не найден (нет Xcode CLT). Пароль будет вводиться через clipboard-paste (fallback)."
  warn "Для форса латинской раскладки: xcode-select --install"
fi

# ---------- step 3: Accessibility ----------

bold "==> Accessibility-права"
if accessibility_ok; then
  note "OK: права уже выданы"
else
  TERM_APP=$(detect_terminal_app || true)
  if [[ -n "$TERM_APP" ]]; then
    printf 'У этого терминала (определил как: \033[1m%s\033[0m) нет прав Accessibility.\n' "$TERM_APP"
    echo "Сейчас откроется Системные настройки → Конфиденциальность и безопасность → Универсальный доступ."
    printf 'Добавь в список \033[1m%s\033[0m и включи галку напротив него.\n' "$TERM_APP"
  else
    echo "Не удалось автоопределить, из какого терминала ты запустил скрипт."
    echo "Сейчас откроется Системные настройки → Конфиденциальность и безопасность → Универсальный доступ."
    echo "Добавь туда свой терминал (Terminal / iTerm / Warp / WezTerm — что используешь) и включи галку."
  fi
  echo "Без этого System Events не сможет нажимать кнопки в приложении."
  echo
  read -rp "Нажми Enter, чтобы открыть Системные настройки..." _ || { err "Нужен интерактивный терминал."; exit 1; }

  # Современный URL (macOS 13+), фолбэк на старый URL, потом на prefPane
  if ! open "x-apple.settings.PrivacySecurity.extension?Privacy_Accessibility" 2>/dev/null; then
    if ! open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null; then
      open "/System/Library/PreferencePanes/Security.prefPane" 2>/dev/null || \
        warn "Не удалось открыть Settings автоматически — открой вручную: Конфиденциальность → Универсальный доступ."
    fi
  fi

  # Цикл проверки — пока не выдадут права
  while true; do
    echo
    read -rp "Когда добавил терминал в список и включил галку — нажми Enter для проверки..." _ || { err "Нужен интерактивный терминал."; exit 1; }
    if accessibility_ok; then
      note "OK: права выданы"
      break
    fi
    warn "System Events всё ещё не имеет доступа."
    if ! ask_yn "Попробовать ещё раз?" Y; then
      err "Без Accessibility скрипт работать не будет. Прерываю установку."
      exit 1
    fi
  done
fi

# ---------- step 4: Креды ----------

bold "==> Креды в Keychain + конфиг"
CREDS_PRESENT=0
if [[ -r "$ACCOUNT_FILE" ]] && security find-generic-password -s "$SERVICE" >/dev/null 2>&1; then
  CREDS_PRESENT=1
  EXISTING_ACCT=$(head -n1 "$ACCOUNT_FILE" | tr -d '\r\n' || true)
  note "Уже сохранено: account=${EXISTING_ACCT}"
fi

if [[ $CREDS_PRESENT -eq 1 ]]; then
  if ask_yn "Перезаписать креды (логин/пароль)?" N; then
    if ! "${SCRIPT_DIR}/setup.sh"; then
      err "Настройка кредов отменена."
      exit 1
    fi
  else
    note "Креды оставлены без изменений."
  fi
else
  if ! "${SCRIPT_DIR}/setup.sh"; then
    err "Настройка кредов отменена."
    exit 1
  fi
fi

# ---------- step 5: Симлинк secure-access-helper ----------

bold "==> Команда secure-access-helper в PATH"

EXPECTED_TARGET="${SCRIPT_DIR}/connect.sh"

# Установить/обновить симлинк по конкретному пути.
# args: <path>  — куда. Использует sudo если dir не writable.
create_symlink() {
  local link="$1" dir
  dir="$(dirname "$link")"
  if [[ -d "$dir" && -w "$dir" ]]; then
    [[ -d "$dir" ]] || mkdir -p "$dir"
    ln -sfn "$EXPECTED_TARGET" "$link"
  else
    [[ -d "$dir" ]] || sudo mkdir -p "$dir"
    sudo ln -sfn "$EXPECTED_TARGET" "$link"
  fi
  hash -r 2>/dev/null || true
}

# 1) Обработать ВСЕ существующие симлинки — каждый stale обновить
existing_count=0
ok_count=0
for cand in "${SYMLINK_CANDIDATES[@]}"; do
  if [[ -L "$cand" ]]; then
    existing_count=$(( existing_count + 1 ))
    current=$(readlink "$cand" 2>/dev/null || true)
    if [[ "$current" == "$EXPECTED_TARGET" ]]; then
      note "OK: ${cand} → ${current}"
      ok_count=$(( ok_count + 1 ))
    else
      warn "Симлинк ${cand} указывает на: ${current}"
      if ask_yn "Перенастроить на ${EXPECTED_TARGET}?" Y; then
        create_symlink "$cand"
        note "OK: ${cand} → ${EXPECTED_TARGET}"
        ok_count=$(( ok_count + 1 ))
      fi
    fi
  fi
done

# 2) Если ни одного не было — предложить создать в лучшей локации
if (( existing_count == 0 )); then
  # Выбрать writable без sudo, иначе первая в списке
  target_link=""
  for cand in "${SYMLINK_CANDIDATES[@]}"; do
    if [[ -d "$(dirname "$cand")" && -w "$(dirname "$cand")" ]]; then
      target_link="$cand"
      break
    fi
  done
  [[ -z "$target_link" ]] && target_link="${SYMLINK_CANDIDATES[0]}"

  if ask_yn "Создать команду '${SYMLINK_NAME}' в ${target_link}?" Y; then
    target_dir="$(dirname "$target_link")"
    [[ -d "$target_dir" && -w "$target_dir" ]] || \
      note "Понадобится sudo для ${target_dir}..."
    create_symlink "$target_link"
    note "OK: ${target_link} → ${EXPECTED_TARGET}"
    ok_count=1

    # PATH-warning только если только что создали
    case ":$PATH:" in
      *":${target_dir}:"*) ;;
      *)
        warn "${target_dir} не в \$PATH этого шелла."
        warn "Открой новый терминал или добавь в свой rc-файл:"
        warn "  export PATH=\"${target_dir}:\$PATH\""
        ;;
    esac
  else
    note "Пропущено. Запускать как: ${SCRIPT_DIR}/connect.sh"
  fi
fi

# ---------- step 6: watchdog-агент (авто-реконнект) ----------

bold "==> Watchdog авто-реконнекта (launchd-агент)"
echo "Агент держит VPN поднятым и автоматически переподключает при обрыве."
echo "Учти: агенту нужен ОТДЕЛЬНЫЙ Accessibility-грант (TCC launchd ≠ терминала)."
if ask_yn "Установить и загрузить watchdog-агент сейчас?" N; then
  "${SCRIPT_DIR}/connect.sh" install-agent || warn "install-agent завершился с ошибкой."
else
  note "Пропущено. Включить позже: secure-access-helper install-agent"
fi

# ---------- step 7: Финал ----------

bold "==> Готово"
echo
echo "Запуск:"
final_link=""
for cand in "${SYMLINK_CANDIDATES[@]}"; do
  if [[ -L "$cand" ]]; then final_link="$cand"; break; fi
done
if [[ -n "$final_link" ]]; then
  echo "  ${SYMLINK_NAME}                # через PATH (из ${final_link})"
fi
echo "  ${SCRIPT_DIR}/connect.sh   # напрямую"
echo
echo "Полезные команды:"
echo "  ${SYMLINK_NAME} status         # состояние туннеля / агента / backoff"
echo "  ${SYMLINK_NAME} doctor         # диагностика окружения"
echo "  ${SYMLINK_NAME} install-agent  # включить watchdog авто-реконнекта"
echo "  ${SYMLINK_NAME} off            # отключить и выключить авто-реконнект"
echo
echo "При первом запуске Keychain Access попросит подтверждение на чтение пароля —"
echo "нажми 'Always Allow', чтобы дальше скрипт работал тихо."
