#!/usr/bin/env bash
# Снятие secure-access-helper: убираем команду из PATH, креды из Keychain и конфиг.
# Сам репозиторий не удаляется — удали папку руками, если нужно.
set -euo pipefail

SERVICE="secure-access-helper"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/secure-access-helper"
ACCOUNT_FILE="${CONFIG_DIR}/account"

# Должен совпадать со списком в install.sh
SYMLINK_NAME="secure-access-helper"
SYMLINK_CANDIDATES=(
  "/opt/homebrew/bin/${SYMLINK_NAME}"
  "/usr/local/bin/${SYMLINK_NAME}"
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

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

bold "==> Конфиг ${CONFIG_DIR}"
# Запомним аккаунт ДО удаления — пригодится для precise-delete Keychain
SAVED_ACCOUNT=""
if [[ -r "$ACCOUNT_FILE" ]]; then
  SAVED_ACCOUNT=$(head -n1 "$ACCOUNT_FILE" | tr -d '\r\n' || true)
fi

if [[ -d "$CONFIG_DIR" ]]; then
  read -rp "Удалить ${CONFIG_DIR}? [y/N] " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR" && note "Удалён."
  else
    note "Оставлен."
  fi
else
  note "Не найден."
fi

bold "==> Keychain (service=${SERVICE})"
read -rp "Удалить пароль из Keychain? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  # Удаляем все записи с этим service (в норме одна, но мало ли).
  # Если знаем account из конфига — используем precise-delete.
  deleted=0
  while true; do
    if [[ -n "$SAVED_ACCOUNT" ]]; then
      security delete-generic-password -a "$SAVED_ACCOUNT" -s "$SERVICE" >/dev/null 2>&1 || break
    else
      security delete-generic-password -s "$SERVICE" >/dev/null 2>&1 || break
    fi
    deleted=$(( deleted + 1 ))
  done
  if (( deleted > 0 )); then
    note "Удалено записей: $deleted"
  else
    note "Запись не найдена."
  fi
else
  note "Оставлено."
fi

bold "==> Готово"
echo "Папку с репозиторием при необходимости удали вручную."
