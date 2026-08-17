# secure-access-helper

Автоподключение к корпоративному VPN-клиенту (Citrix Secure Access / NetScaler)
на macOS через UI scripting **+ watchdog авто-реконнекта**: держит туннель
поднятым и автоматически переподключается, если соединение отвалилось.

Хранит пароль в Keychain, заполняет форму авторизации скриптом, жмёт
«Подтвердить», обрабатывает диалог «Transfer Logon» и — главное — подтверждает
успех **авторитетно через `scutil`** (реально ли встал туннель), а не по тому,
закрылось ли окно.

## Зачем

- VPN-клиент при каждом подключении просит пароль (чекбокс «Сохранить
  настройки» пароль не хранит). Скрипт убирает ручной ввод.
- Соединение периодически рвётся (сон/пробуждение, смена сети, таймаут шлюза).
  Watchdog замечает обрыв и переподключается сам.

## Состав

| Файл                                   | Назначение                                                        |
| -------------------------------------- | ----------------------------------------------------------------- |
| `install.sh`                           | Установка на новой машине (+ сборка хелпера, опц. агент)           |
| `uninstall.sh`                         | Снятие: агент, симлинк, конфиг, Keychain                           |
| `setup.sh`                             | Сохраняет логин (конфиг) и пароль (Keychain, без argv-экспозиции)  |
| `connect.sh`                           | CLI: `connect`/`status`/`off`/`pause`/`watch`/`doctor`/`install-agent`… |
| `citrix-vpn-watchdog`                  | Цикл авто-реконнекта (точка входа LaunchAgent; без `.sh` — имя видно в Login Items) |
| `lib.sh`                               | Общие хелперы (scutil-состояние, backoff, lock, уведомления)      |
| `fill.applescript`                     | UI scripting: клики, ввод пароля (layout-safe), sheet'ы           |
| `setlayout.swift`                      | Хелпер форса латинской раскладки (собирается в `bin/setlayout`)   |
| `com.nqs.secure-access-helper.watchdog.plist.template` | Шаблон LaunchAgent для watchdog                   |
| `debug-inspect.applescript`            | Дамп AX-дерева окон — только для отладки                          |

## Требования

- macOS (тестировалось на 15.x/26.x).
- Установленный VPN-клиент (имя приложения — `property kAppName` в `fill.applescript`).
- В приложении хотя бы раз вручную добавлено и выбрано рабочее подключение.
- Xcode Command Line Tools (`swiftc`) — для хелпера раскладки. Без него ввод
  пароля откатывается на clipboard-paste (тоже работает).

## Установка на новой машине

```bash
git clone <repo-url> ~/Projects/setup/secure-access-helper
cd ~/Projects/setup/secure-access-helper
./install.sh
```

`install.sh` идемпотентный. Шаги:

1. Проверяет наличие целевого приложения в `/Applications`.
2. Делает скрипты исполняемыми **и собирает `bin/setlayout`** через `swiftc`.
3. **Accessibility-права** для терминала (с проверкой в цикле, пока не выдашь).
4. **Креды.** Логин → `~/.config/secure-access-helper/account` (0600); пароль
   вводится в собственный промпт `security` (в argv/`ps` не попадает) → Keychain.
5. **Команда `secure-access-helper`** — симлинк на `connect.sh` в `PATH`.
6. **Опционально** — установить watchdog-агент авто-реконнекта (по умолчанию нет).

При **первом** запуске macOS покажет диалог Keychain — жми **Always Allow**.

## Использование

```bash
secure-access-helper              # подключиться (по умолчанию)
secure-access-helper status       # состояние туннеля / агента / backoff
secure-access-helper doctor       # диагностика окружения
secure-access-helper off          # отключить и ВЫКЛЮЧИТЬ авто-реконнект (desired=down)
secure-access-helper pause 2h     # пауза watchdog на 2 часа (или без арг — до resume)
secure-access-helper resume       # снять паузу
```

Что делает `connect`:
1. **Fast-path:** если `scutil` уже говорит `Connected` — выходит сразу,
   не трогая UI (ни фокуса, ни Keychain).
2. Иначе активирует приложение, при необходимости разруливает забытый sheet.
3. На Home жмёт **Connect** (внутри WebView это `AXLink`).
4. Дожидается auth-формы (ищет её **структурно** — по наличию secure-поля),
   вводит пароль (см. ниже), жмёт submit, обрабатывает **Transfer Logon**.
5. **Подтверждает успех через `scutil --nc status` (== `Connected`)** — и только
   тогда возвращает успех. До 3 попыток с корректным quit между ними.

### Как вводится пароль (layout-safe)

`keystroke` в AppleScript зависит от активной раскладки: под кириллицей пароль
уходит мусором в WebView. Поэтому перед вводом:

1. **`layout` (по умолчанию):** `bin/setlayout` форсит латинскую (ASCII)
   раскладку → `keystroke` → раскладка возвращается. Пароль **не** идёт в буфер обмена.
2. **fallback `clipboard`:** если хелпер недоступен — Cmd+V (пароль ~0.2с в буфере,
   потом чистится/восстанавливается прежнее содержимое).
3. **`keystroke`:** режим «как есть» — под нелатинской раскладкой ввод **не**
   выполняется (ошибка + отложить), чтобы не слать мусор и не залочить аккаунт.

Метод задаётся `property kInjectMethod` в `fill.applescript`. Перед вводом
скрипт проверяет, что secure-поле **в фокусе** (`AXFocused`) и приложение
**frontmost** — иначе пароль не вводится.

## Авто-реконнект (watchdog)

Включить:

```bash
secure-access-helper install-agent      # ставит + грузит LaunchAgent
```

Как работает `citrix-vpn-watchdog` (раз в `SAH_INTERVAL`, сигнал — **scutil**):

| Состояние scutil            | Действие                                                        |
| --------------------------- | -------------------------------------------------------------- |
| `Connected`                 | ничего; сбросить backoff (**только** тут)                      |
| `Connecting`/`Disconnecting`| ничего (не мешать своему коннекту/дисконнекту)                 |
| `Invalid`/`NoService`       | уведомить один раз, не долбить UI                              |
| `Disconnected` (устойчиво)  | реконнект через `connect.sh`, если выполнены условия ↓         |

Реконнект запускается, только когда: `desired=up` **и** не на паузе **и** есть
физический аплинк (проверка через `route`/`ifconfig`, **не** через прокси) **и**
вышли из окна backoff **и** дебаунс подтвердил устойчивый обрыв (`SAH_DEBOUNCE`
подряд) **и** прямо перед действием состояние всё ещё `Disconnected` (TOCTOU).

Защита от «шторма»: экспоненциальный backoff (переживает рестарт агента),
уведомление после `SAH_NOTIFY_AFTER` неудач, «сдаюсь» после `SAH_GIVEUP_AFTER`
(до смены состояния/`desired`). Уведомления дублируются в `~/.config/.../status`,
т.к. под launchd `display notification` может молча не показаться.

### ⚠️ Ограничения фонового агента

1. **Accessibility.** launchd запускает `osascript` в **своём** TCC-контексте —
   грант терминала на него **не распространяется**, и macOS **не покажет попап**
   фоновому агенту. Если авто-реконнект молчит:

   > Системные настройки → Конфиденциальность и безопасность → **Универсальный
   > доступ** → включи пункт для агента (может называться `bash` или `osascript`).

   Грант TCC привязан к **интерпретатору** (`/bin/bash`), а не к имени скрипта,
   поэтому здесь пункт так и останется `bash` — в отличие от Login Items (см. п. 4).
   На свежих macOS такой пункт для голого `/bin/bash → osascript` иногда не
   появляется/не «прилипает» — тогда фоновый реконнект не заработает (ограничение
   TCC); держи VPN ручным `connect`/хоткеем.
2. **Только разблокированная GUI-сессия.** На экране логина или при заблокированном
   Keychain реконнект не пройдёт (нет ни доступа к паролю, ни к UI).
3. **`doctor` проверяет контекст терминала, не агента** — его «ok» по Accessibility
   не гарантирует грант агенту. Реальная проверка — живой обрыв + лог.
4. **Имя в Login Items.** macOS показывает в «Основные → Объекты входа и расширения»
   basename из `ProgramArguments[0]`, поэтому агент запускает скрипт напрямую
   (shebang + бит `+x`), а не через `/bin/bash <скрипт>` — иначе в списке был бы
   безликий `bash`. Отсюда и имя файла без расширения: `citrix-vpn-watchdog`.

Лог: `~/Library/Logs/secure-access-helper.watchdog.log`.

### Намеренно отключиться

`secure-access-helper off` ставит `desired=down` и роняет туннель — watchdog
**не** будет переподключать. Обратно — `secure-access-helper connect` (или
`install-agent`). Если отключаешься через **родное** меню Citrix, watchdog этого
не знает и переподключит — используй `off` или `pause`.

### Настройки

Env или файл `~/.config/secure-access-helper/config` (`KEY=value`):

| Переменная            | Дефолт | Смысл                                   |
| --------------------- | ------ | --------------------------------------- |
| `SAH_INTERVAL`        | 30     | период опроса, с                        |
| `SAH_DEBOUNCE`        | 2      | подряд `Disconnected` до реакции        |
| `SAH_BACKOFF_BASE`    | 60     | база backoff, с                         |
| `SAH_BACKOFF_MAX`     | 1800   | потолок backoff, с                      |
| `SAH_NOTIFY_AFTER`    | 3      | неудач до уведомления                   |
| `SAH_GIVEUP_AFTER`    | 8      | неудач до «сдаюсь» (sticky)             |
| `SAH_VERIFY_TIMEOUT`  | 25     | ждать `Connected` после ввода, с        |

## Конфигурация

Аккаунт (первое непустое): `SECURE_ACCESS_ACCOUNT` → `~/.config/secure-access-helper/account`
→ парсинг Keychain. Имя приложения, сервис Keychain, списки имён кнопок и способ
ввода пароля — в начале `fill.applescript`. Сервис Citrix в `scutil` находится по
bundle-id `com.citrix.NetScalerGateway` (не по хосту — репозиторий корп-агностик).

## Что если ломается

1. **`osascript is not allowed assistive access`** — нет Accessibility-прав
   (у терминала — перезапусти `install.sh`; у **агента** — см. раздел выше).
2. **`secure-поле не получило фокус` / `не стал frontmost`** — фокус не
   переключился; не работай в фуллскрине другого приложения, повтори.
3. **`AXSecureTextField не найден`** — изменилась структура AX-дерева (новый
   билд/локаль). Сними дамп при открытом auth-окне и сравни с `fill.applescript`:
   ```bash
   osascript ~/Projects/setup/secure-access-helper/debug-inspect.applescript > ~/axdump.txt
   ```
4. **Пароль набирается мусором** — не собрался `bin/setlayout` и активна
   нелатинская раскладка. Поставь Xcode CLT (`xcode-select --install`) и
   перезапусти `install.sh`, либо переключись на ABC/EN вручную.
5. **`scutil` так и не показывает `Connected`** — проблема не в автоматизации
   (пароль/шлюз/сеть). Смотри `secure-access-helper status` и лог watchdog.

## Безопасность

- Пароль — в macOS Keychain. `setup.sh` вводит его в собственный промпт
  `security` (с подтверждением), поэтому пароль **не** попадает в argv/`ps`.
- `setup.sh` ставит ACL `-T /usr/bin/security`, чтобы фоновый агент читал пароль
  без GUI-подтверждения. Размен: любой процесс от твоего имени тоже сможет
  прочитать пароль через `security -w` без попапа. Существующим установкам —
  перезапусти `setup.sh`, чтобы ACL применился.
- При вводе AppleScript читает пароль через `security … -w` (в момент логина,
  на диск не пишется). Перед `keystroke` проверяется `AXFocused` secure-поля и
  `frontmost` приложения — иначе пароль **не** вводится (не улетит в чужое окно).
- Фолбэк на обычное text field **не** делается (пароль не окажется в видимом поле).
- В режиме `layout` пароль не касается буфера обмена; в `clipboard` — буфер
  чистится/восстанавливается сразу (на этой машине менеджера буфера нет).
- Логин (`account`) — 0600 в `~/.config/`.

## Перенос корп-сертификата (client identity)

`secure-access-helper` автоматизирует только ввод пароля. Доступ к Gateway даёт
**клиентский сертификат (identity)** в Keychain + корп CA-цепочка — без них
коннекта нет. Серт user-bound (не привязан к железу) → переносим.

1. Старая машина: Keychain Access → запись с приватным ключом (label = фамилия) →
   Export → `.p12` (с паролем).
   CLI: `security export -k login.keychain-db -t identities -f pkcs12 -o cert.p12`.
2. Перенести защищённым каналом (AirDrop / scp по Tailscale-LAN), **не облаком**;
   после импорта файл удалить.
3. Новая: `security import cert.p12 -k ~/Library/Keychains/login.keychain-db`
   (или двойной клик в Keychain Access).
4. Импортировать корп root/intermediate CA (`.cer`) в **System** keychain.
5. Дальше обычный `install.sh` + `setup.sh`.

**Мульти-девайс:** один user-серт на нескольких машинах работает, но NetScaler
покажет **Transfer Logon** и зафиксирует второй serial в audit. **Не держать две
активные корп-сессии одновременно.** Когда mini станет основным — убрать identity
со старой машины (Keychain Access → удалить), но **не отзывать** серт. Не
коммитить `.p12`/`.cer`/`account` в git.

## Снятие

```bash
~/Projects/setup/secure-access-helper/uninstall.sh
```

Выгрузит watchdog-агент, уберёт симлинк, спросит про конфиг (вместе с
`desired`/`paused`/`watchdog.state`), запись в Keychain (точечно по account +
подчистка по service) и лог. Репозиторий не трогает.
