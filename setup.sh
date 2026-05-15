#!/usr/bin/env bash
# Сохраняет логин (в конфиг-файл) и пароль (в macOS Keychain) для secure-access-helper.
# Сначала пароль в Keychain, потом логин в файл — если Keychain зафейлит,
# не оставляем висячий конфиг без пароля.
set -euo pipefail

SERVICE="secure-access-helper"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/secure-access-helper"
ACCOUNT_FILE="${CONFIG_DIR}/account"

DEFAULT_ACCOUNT="${SECURE_ACCESS_ACCOUNT:-}"
# Если уже что-то есть в конфиге — предложим как дефолт
if [[ -z "$DEFAULT_ACCOUNT" && -r "$ACCOUNT_FILE" ]]; then
  DEFAULT_ACCOUNT=$(head -n1 "$ACCOUNT_FILE" | tr -d '\r\n')
fi

if [[ -n "$DEFAULT_ACCOUNT" ]]; then
  read -rp "Логин (Имя пользователя VPN) [${DEFAULT_ACCOUNT}]: " ACCOUNT
  ACCOUNT="${ACCOUNT:-$DEFAULT_ACCOUNT}"
else
  read -rp "Логин (Имя пользователя VPN): " ACCOUNT
fi
if [[ -z "${ACCOUNT}" ]]; then
  echo "Логин не может быть пустым" >&2
  exit 1
fi

read -rsp "Пароль: " PASSWORD
echo
# Гарантируем, что PASSWORD очистится при любом завершении скрипта
trap 'unset PASSWORD' EXIT INT TERM
if [[ -z "${PASSWORD}" ]]; then
  echo "Пароль не может быть пустым" >&2
  exit 1
fi

# 1) Сначала пароль в Keychain (если зафейлит — конфиг не создадим)
if ! security add-generic-password \
       -a "${ACCOUNT}" \
       -s "${SERVICE}" \
       -w "${PASSWORD}" \
       -U \
       -j "secure-access-helper" 2>/dev/null; then
  echo "Не удалось записать пароль в Keychain." >&2
  echo "Возможно, связка ключей заблокирована (Keychain Access → Login → Unlock)." >&2
  exit 1
fi

# 2) Логин в конфиг-файл (0600)
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
printf '%s\n' "$ACCOUNT" > "$ACCOUNT_FILE"
chmod 600 "$ACCOUNT_FILE"

echo
echo "Сохранено:"
echo "  keychain:     service=${SERVICE} account=${ACCOUNT}"
echo "  account file: ${ACCOUNT_FILE}"
