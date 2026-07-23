#!/usr/bin/env bash
# secure-access-helper watchdog — держит Citrix VPN поднятым и переподключает при обрыве.
# Обычно запускается launchd-агентом (com.nqs.secure-access-helper.watchdog).
#
# Логика тика (раз в SAH_INTERVAL секунд), сигнал состояния — АВТОРИТЕТНЫЙ scutil:
#   Connected                  -> ничего; сбросить backoff (только тут!)
#   Connecting/Disconnecting   -> ничего (не мешать своему коннекту/дисконнекту)
#   Invalid/NoService/Unknown  -> не долбить UI; уведомить один раз
#   Disconnected (устойчиво)   -> при desired=up, не на паузе, есть аплинк, вышли из backoff
#                                 -> реконнект через connect.sh (он сам верифицирует scutil)
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

STOP=0
trap 'STOP=1' TERM INT

consec_down=0
prev_state=""
load_state   # -> FAIL_COUNT, NEXT_ATTEMPT (переживают рестарт агента)

tick() {
  is_paused && return 0
  [ "$(get_desired)" = "down" ] && { consec_down=0; return 0; }

  local st; st=$(citrix_state)
  local prev="$prev_state"
  prev_state="$st"

  case "$st" in
    Connected)
      consec_down=0
      # Любой переход НЕ-Connected -> Connected снимает все маркеры уведомлений
      # (в т.ч. config-маркер, который иначе завис бы навсегда и проглотил бы
      # следующее реальное падение).
      [ "$prev" != "Connected" ] && clear_notify
      if [ "$FAIL_COUNT" -ne 0 ]; then
        FAIL_COUNT=0; NEXT_ATTEMPT=0; save_state
        notify_once recovered "Citrix VPN: соединение восстановлено"
      fi
      return 0 ;;

    Connecting|Disconnecting)
      # переходное состояние — не трогаем, backoff НЕ сбрасываем и consec_down НЕ
      # обнуляем (иначе флап Disconnected/Connecting никогда не добрал бы дебаунс).
      return 0 ;;

    NoService|Invalid|Unknown)
      # consec_down не трогаем (см. выше); UI не долбим.
      notify_once config "Citrix VPN: сервис недоступен/сломан ($st) — проверь профиль подключения"
      return 0 ;;

    Disconnected)
      consec_down=$((consec_down + 1))
      [ "$consec_down" -lt "$SAH_DEBOUNCE" ] && return 0

      if [ "$SAH_GIVEUP_AFTER" -gt 0 ] && [ "$FAIL_COUNT" -ge "$SAH_GIVEUP_AFTER" ]; then
        notify_once giveup "Citrix VPN: сдаюсь после $FAIL_COUNT неудач — проверь пароль/шлюз (secure-access-helper status)"
        return 0
      fi

      local now; now=$(epoch)
      [ "$now" -lt "$NEXT_ATTEMPT" ] && return 0

      if ! has_uplink; then sah_log "нет аплинка — откладываю реконнект"; return 0; fi

      # TOCTOU: перепроверяем прямо перед действием (Citrix мог сам начать реконнект).
      # consec_down здесь НЕ сбрасываем — при флапе он должен продолжать копиться.
      local now_state; now_state=$(citrix_state)
      if [ "$now_state" != "Disconnected" ]; then
        sah_log "состояние сменилось на $now_state — пропускаю"; return 0
      fi

      sah_log "авто-реконнект (fail_count=$FAIL_COUNT)"
      local rc
      SAH_WATCHDOG=1 "$SCRIPT_DIR/connect.sh" connect >>"$WATCHDOG_LOG" 2>&1
      rc=$?
      if [ "$rc" -eq 0 ]; then
        FAIL_COUNT=0; NEXT_ATTEMPT=0; save_state; consec_down=0
        clear_notify
        notify_once recovered "Citrix VPN: переподключено"
        sah_log "реконнект удался"
      elif [ "$rc" -eq "$LOCK_BUSY" ]; then
        # занят другим (ручным) подключением — это НЕ провал, не трогаем счётчики
        sah_log "занят другим подключением (lock) — не считаю за неудачу"
      else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        local backoff; backoff=$(compute_backoff "$FAIL_COUNT")
        # backoff отсчитываем от МОМЕНТА неудачи (connect.sh мог идти ~1-2 мин),
        # иначе now+backoff уже в прошлом и пауза не срабатывает.
        NEXT_ATTEMPT=$(( $(epoch) + backoff ))
        save_state
        sah_log "реконнект не удался (rc=$rc) — backoff ${backoff}s (fail_count=$FAIL_COUNT)"
        [ "$FAIL_COUNT" -ge "$SAH_NOTIFY_AFTER" ] \
          && notify_once fail "Citrix VPN: не удаётся переподключиться ($FAIL_COUNT попыток)"
      fi
      return 0 ;;

    *)
      return 0 ;;
  esac
}

sah_log "watchdog старт (interval=${SAH_INTERVAL}s debounce=${SAH_DEBOUNCE} backoff=${SAH_BACKOFF_BASE}..${SAH_BACKOFF_MAX}s)"
while [ "$STOP" -eq 0 ]; do
  tick || sah_log "tick: ошибка проигнорирована"
  # прерываемый сон: реагируем на SIGTERM быстрее, чем через полный интервал
  slept=0
  while [ "$slept" -lt "$SAH_INTERVAL" ] && [ "$STOP" -eq 0 ]; do
    sleep 1
    slept=$((slept + 1))
  done
done
sah_log "watchdog остановлен."
