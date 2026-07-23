#!/usr/bin/env bash
# Сохраняет логин (в конфиг-файл) и пароль (в macOS Keychain) для secure-access-helper.
# Пароль вводится в собственный промпт `security` (с подтверждением) — так он НЕ
# попадает в argv процесса (в отличие от `-w "$PASSWORD"`, который виден в `ps`).
set -euo pipefail

SERVICE="secure-access-helper"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/secure-access-helper"
ACCOUNT_FILE="${CONFIG_DIR}/account"

DEFAULT_ACCOUNT="${SECURE_ACCESS_ACCOUNT:-}"
if [[ -z "$DEFAULT_ACCOUNT" && -r "$ACCOUNT_FILE" ]]; then
  DEFAULT_ACCOUNT=$(head -n1 "$ACCOUNT_FILE" | tr -d '\r\n')
fi

if [[ -n "$DEFAULT_ACCOUNT" ]]; then
  read -rp "Логин (Имя пользователя VPN) [${DEFAULT_ACCOUNT}]: " ACCOUNT || { echo "Отменено." >&2; exit 1; }
  ACCOUNT="${ACCOUNT:-$DEFAULT_ACCOUNT}"
else
  read -rp "Логин (Имя пользователя VPN): " ACCOUNT || { echo "Отменено." >&2; exit 1; }
fi
if [[ -z "${ACCOUNT}" ]]; then
  echo "Логин не может быть пустым" >&2
  exit 1
fi

# Пароль спрашивает сам `security` (`-w` в конце, без значения) — с подтверждением,
# скрытым вводом и БЕЗ появления пароля в командной строке.
# `-T /usr/bin/security` даёт этому инструменту читать пароль без GUI-попапа
# «Always Allow» — иначе первый unattended-реконнект агента завис бы на диалоге,
# который фоновому агенту некому подтвердить. (Тонкий размен: любой процесс от
# твоего имени сможет прочитать пароль через `security -w` без подтверждения.)
echo "Введи пароль VPN (security спросит его сам, ввод скрыт, с подтверждением):"
if ! security add-generic-password \
       -a "${ACCOUNT}" \
       -s "${SERVICE}" \
       -U \
       -j "secure-access-helper" \
       -T /usr/bin/security \
       -w; then
  echo "Не удалось записать пароль в Keychain (или ввод отменён)." >&2
  echo "Если связка заблокирована: Keychain Access → Login → Unlock, и повтори." >&2
  exit 1
fi

# Логин в конфиг-файл (0600) — только после успешной записи пароля.
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
printf '%s\n' "$ACCOUNT" > "$ACCOUNT_FILE"
chmod 600 "$ACCOUNT_FILE"

echo
echo "Сохранено:"
echo "  keychain:     service=${SERVICE} account=${ACCOUNT}"
echo "  account file: ${ACCOUNT_FILE}"
