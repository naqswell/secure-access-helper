#!/usr/bin/env bash
# Снятие secure-access-helper: выгружаем watchdog-агент, убираем команду из PATH,
# креды из Keychain и конфиг (вместе с desired/paused/state-файлами).
# Сам репозиторий не удаляется — удали папку руками, если нужно.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE="secure-access-helper"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/secure-access-helper"
ACCOUNT_FILE="${CONFIG_DIR}/account"
WATCHDOG_LOG="$HOME/Library/Logs/secure-access-helper.watchdog.log"

SYMLINK_NAME="secure-access-helper"
SYMLINK_CANDIDATES=(
  "/opt/homebrew/bin/${SYMLINK_NAME}"
  "/usr/local/bin/${SYMLINK_NAME}"
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

# ---------- watchdog-агент ----------
bold "==> Агент watchdog"
if [[ -x "$SCRIPT_DIR/connect.sh" ]]; then
  "$SCRIPT_DIR/connect.sh" uninstall-agent || warn "не удалось выгрузить агент (возможно, он и не был установлен)."
else
  note "connect.sh не найден — пропускаю выгрузку агента."
fi

# ---------- симлинки в PATH ----------
bold "==> Симлинки в PATH"
found_any=0
for cand in "${SYMLINK_CANDIDATES[@]}"; do
  if [[ -L "$cand" ]]; then
    found_any=1
    cand_dir="$(dirname "$cand")"
    if [[ -w "$cand_dir" ]]; then
      rm "$cand" && note "Удалён: $cand"
    else
      sudo rm "$cand" && note "Удалён (sudo): $cand"
    fi
  fi
done
[[ $found_any -eq 0 ]] && note "Симлинки не найдены."

# ---------- конфиг (+ desired/paused/state) ----------
bold "==> Конфиг ${CONFIG_DIR}"
# Запомним аккаунт ДО удаления — для precise-delete Keychain.
SAVED_ACCOUNT=""
if [[ -r "$ACCOUNT_FILE" ]]; then
  SAVED_ACCOUNT=$(head -n1 "$ACCOUNT_FILE" | tr -d '\r\n' || true)
fi

if [[ -d "$CONFIG_DIR" ]]; then
  read -rp "Удалить ${CONFIG_DIR} (account, desired, paused, watchdog.state)? [y/N] " yn || yn=""
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR" && note "Удалён."
  else
    note "Оставлен."
  fi
else
  note "Не найден."
fi

# ---------- Keychain ----------
bold "==> Keychain (service=${SERVICE})"
read -rp "Удалить пароль из Keychain? [y/N] " yn || yn=""
if [[ "$yn" =~ ^[Yy]$ ]]; then
  deleted=0
  # 1) точечно по известному account
  if [[ -n "$SAVED_ACCOUNT" ]]; then
    while security delete-generic-password -a "$SAVED_ACCOUNT" -s "$SERVICE" >/dev/null 2>&1; do
      deleted=$(( deleted + 1 ))
    done
  fi
  # 2) затем по service — выметаем записи под ЛЮБЫМ account (иначе осиротеют)
  while security delete-generic-password -s "$SERVICE" >/dev/null 2>&1; do
    deleted=$(( deleted + 1 ))
  done
  if (( deleted > 0 )); then note "Удалено записей: $deleted"; else note "Запись не найдена."; fi
else
  note "Оставлено."
fi

# ---------- лог ----------
if [[ -f "$WATCHDOG_LOG" ]]; then
  read -rp "Удалить лог ${WATCHDOG_LOG}? [y/N] " yn || yn=""
  [[ "$yn" =~ ^[Yy]$ ]] && rm -f "$WATCHDOG_LOG" && note "Лог удалён." || note "Лог оставлен."
fi

bold "==> Готово"
echo "Папку с репозиторием при необходимости удали вручную."
