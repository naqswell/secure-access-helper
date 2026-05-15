-- Автоподключение secure-access-helper.
-- Поток:
--   1) Окно Home — внутри WebView кнопка Connect (AXLink).
--   2) После клика появляется auth-форма (то же окно, title содержит "auth")
--      с AXSecureTextField внутри AXWebArea и AXLink "Подтвердить" — заполняем пароль.
--   3) Если показывается sheet "Transfer Logon" — жмём Transfer.
--
-- Usage: osascript fill.applescript <account>
-- Возвращает: "ok" / "alreadyConnected" / "windowNotAppeared" / "ERROR: <reason>"

property kAppName : "Citrix Secure Access"
property kKeychainService : "secure-access-helper"

-- Защита от бесконечной рекурсии при обходе AX-дерева. WebView внутри Citrix имеет
-- глубину ~10, ставим запас.
property kMaxAxDepth : 25

-- Home-окно: кнопка Connect
property kConnectNames : {"Connect", "Подключиться", "Подключить"}
-- Home-окно: статус "уже подключено". На кнопке Citrix реально пишется "Log off" —
-- держим все правдоподобные варианты, AppleScript `is` case-insensitive по умолчанию.
property kDisconnectNames : {"Log off", "Log Off", "Log out", "Log Out", "Sign off", "Sign Off", "Sign out", "Sign Out", "Disconnect", "Отключить", "Отключиться", "Выйти"}
-- Auth-форма: submit (НЕ должен пересекаться с kConnectNames — иначе на auth-окне
-- может случайно сматчить остатки Home-панели).
property kSubmitNames : {"Подтвердить", "Submit", "Sign in", "Войти", "OK"}
-- Sheet "Transfer Logon"
property kTransferButtonNames : {"Transfer", "Передать", "Перенести"}
-- Прочие модальные диалоги
property kOkButtonNames : {"OK", "Continue", "Продолжить", "Yes", "Да"}

-- ---------- AX-обход (рекурсивный поиск) ----------

on findFirstSecureField(rootElt)
	return my findFirstSecureFieldD(rootElt, 0)
end findFirstSecureField

on findFirstSecureFieldD(rootElt, depth)
	if depth > kMaxAxDepth then return missing value
	tell application "System Events"
		try
			if (role of rootElt) is "AXTextField" then
				try
					if (subrole of rootElt) is "AXSecureTextField" then return rootElt
				end try
			end if
		end try
		set kids to {}
		try
			set kids to UI elements of rootElt
		end try
	end tell
	repeat with k in kids
		set found to my findFirstSecureFieldD(k, depth + 1)
		if found is not missing value then return found
	end repeat
	return missing value
end findFirstSecureFieldD

-- Найти AXLink или AXButton с подходящим именем (любая глубина).
on findClickableByName(rootElt, candidates)
	return my findClickableByNameD(rootElt, candidates, 0)
end findClickableByName

on findClickableByNameD(rootElt, candidates, depth)
	if depth > kMaxAxDepth then return missing value
	tell application "System Events"
		try
			set r to (role of rootElt) as string
			if r is "AXLink" or r is "AXButton" then
				try
					set nm to (name of rootElt) as string
					repeat with c in candidates
						if nm is (c as string) then return rootElt
					end repeat
				end try
			end if
		end try
		set kids to {}
		try
			set kids to UI elements of rootElt
		end try
	end tell
	repeat with k in kids
		set found to my findClickableByNameD(k, candidates, depth + 1)
		if found is not missing value then return found
	end repeat
	return missing value
end findClickableByNameD

-- Рекурсивно ищем AXSheet в дереве элемента.
on findSheet(rootElt)
	return my findSheetD(rootElt, 0)
end findSheet

on findSheetD(rootElt, depth)
	if depth > kMaxAxDepth then return missing value
	tell application "System Events"
		try
			if (role of rootElt) is "AXSheet" then return rootElt
		end try
		set kids to {}
		try
			set kids to UI elements of rootElt
		end try
	end tell
	repeat with k in kids
		set found to my findSheetD(k, depth + 1)
		if found is not missing value then return found
	end repeat
	return missing value
end findSheetD

-- ---------- Окна приложения ----------

on getAppWindow()
	tell application "System Events"
		if not (exists process kAppName) then return missing value
		tell process kAppName
			if (count of windows) = 0 then return missing value
			return window 1
		end tell
	end tell
end getAppWindow

on getAppWindowByTitleContains(needle)
	tell application "System Events"
		if not (exists process kAppName) then return missing value
		tell process kAppName
			repeat with w in windows
				try
					if (title of w) as string contains needle then return w
				end try
			end repeat
		end tell
	end tell
	return missing value
end getAppWindowByTitleContains

-- Ждёт, пока приложение реально станет frontmost. Критично перед keystroke —
-- иначе пароль может уйти в терминал/другое приложение.
on waitForFrontmost(timeoutSec)
	set waited to 0
	repeat while waited < timeoutSec
		tell application "System Events"
			try
				if frontmost of process kAppName is true then return true
			end try
		end tell
		delay 0.1
		set waited to waited + 0.1
	end repeat
	return false
end waitForFrontmost

-- Проверяет, что в окне есть AXPopUpButton с непустым value, похожим на host/URL
-- (содержит точку, двоеточие или слеш). Это специфично для Connection-дропдауна Home —
-- отсекает обычные menu popup'ы вроде File/Edit с дефолтным значением.
-- Смотрим только на прямые UI-элементы окна (Connection-popup в Citrix Home лежит
-- на верхнем уровне), без глубокой рекурсии.
on hasConfiguredConnection(window_)
	tell application "System Events"
		set kids to {}
		try
			set kids to UI elements of window_
		end try
		repeat with k in kids
			try
				if (role of k) is "AXPopUpButton" then
					try
						set v to (value of k) as string
						if v is not "" and ¬
							(v contains "." or v contains ":" or v contains "/") then
							return true
						end if
					end try
				end if
			end try
		end repeat
	end tell
	return false
end hasConfiguredConnection

on findAnySheet()
	tell application "System Events"
		if not (exists process kAppName) then return missing value
		tell process kAppName
			repeat with w in windows
				set sh to my findSheet(w)
				if sh is not missing value then return sh
			end repeat
		end tell
	end tell
	return missing value
end findAnySheet

on collectStaticTexts(rootElt)
	return my collectStaticTextsD(rootElt, 0)
end collectStaticTexts

on collectStaticTextsD(rootElt, depth)
	set result to {}
	if depth > kMaxAxDepth then return result
	tell application "System Events"
		try
			if (role of rootElt) is "AXStaticText" then
				try
					set v to value of rootElt
					if v is not missing value then set end of result to (v as string)
				end try
			end if
		end try
		set kids to {}
		try
			set kids to UI elements of rootElt
		end try
	end tell
	repeat with k in kids
		set subResults to my collectStaticTextsD(k, depth + 1)
		repeat with sR in subResults
			set end of result to sR
		end repeat
	end repeat
	return result
end collectStaticTextsD

-- Обработка sheet'ов (Transfer Logon и т.п.). Можно звать несколько раз.
on handleSheetIfAny(timeoutSec)
	set waited to 0
	repeat while waited < timeoutSec
		set sh to my findAnySheet()
		if sh is not missing value then
			set sheetText to ""
			try
				set texts to my collectStaticTexts(sh)
				repeat with t in texts
					set sheetText to sheetText & " " & t
				end repeat
			end try

			set btn to missing value
			if sheetText contains "Transfer Logon" or sheetText contains "logged on to the server from another" then
				set btn to my findClickableByName(sh, kTransferButtonNames)
			end if
			if btn is missing value then
				set btn to my findClickableByName(sh, kOkButtonNames)
			end if
			if btn is missing value then
				set btn to my findClickableByName(sh, kTransferButtonNames)
			end if

			if btn is not missing value then
				try
					tell application "System Events" to click btn
				on error
					try
						tell application "System Events" to perform action "AXPress" of btn
					end try
				end try
				delay 1.0
				if (my findAnySheet()) is missing value then return true
			end if
		end if
		delay 0.5
		set waited to waited + 0.5
	end repeat
	return false
end handleSheetIfAny

-- ---------- Focus / UX ----------

-- Запоминает имя процесса, который был frontmost — чтобы вернуть фокус в конце.
on captureFrontmostApp()
	try
		tell application "System Events"
			return name of first process whose frontmost is true
		end tell
	end try
	return missing value
end captureFrontmostApp

-- Возвращает фокус приложению, которое было frontmost в начале.
on restoreFocusTo(procName)
	if procName is missing value then return
	if procName is kAppName then return
	try
		tell application "System Events" to set frontmost of process procName to true
	end try
end restoreFocusTo

-- Сворачивает все окна целевого приложения (после успешного коннекта Citrix живёт
-- в menu bar, окна на экране не нужны).
on minimizeAllAppWindows()
	tell application "System Events"
		if not (exists process kAppName) then return
		tell process kAppName
			repeat with w in windows
				try
					set minBtn to first button of w whose subrole is "AXMinimizeButton"
					click minBtn
				end try
			end repeat
		end tell
	end tell
end minimizeAllAppWindows

-- ---------- Main ----------

on run argv
	set prevApp to my captureFrontmostApp()
	-- NB: имя `result` зарезервировано AppleScript (implicit last-expr) — не используем.
	set outcome to my mainFlow(argv)
	-- Постобработка: сворачиваем окна только при успехе; фокус возвращаем всегда.
	if outcome is "ok" or outcome is "alreadyConnected" then
		try
			my minimizeAllAppWindows()
		end try
	end if
	my restoreFocusTo(prevApp)
	return outcome
end run

on mainFlow(argv)
	if (count of argv) < 1 then return "ERROR: account argument missing"
	set theAccount to item 1 of argv

	try
		set thePass to do shell script "security find-generic-password -a " & quoted form of theAccount & " -s " & quoted form of kKeychainService & " -w"
	on error errMsg
		return "ERROR: keychain access failed: " & errMsg
	end try

	tell application kAppName to activate

	-- Если sheet уже висит с прошлой попытки (например, забытый Transfer Logon) —
	-- разруливаем его сразу, до основной логики.
	my handleSheetIfAny(3)

	-- Ждём появления окна
	set waited to 0
	set theWindow to missing value
	repeat while waited < 20
		set theWindow to my getAppWindow()
		if theWindow is not missing value then exit repeat
		delay 0.5
		set waited to waited + 0.5
	end repeat
	if theWindow is missing value then return "windowNotAppeared"

	-- Auth-окно или Home?
	set isAuth to false
	try
		tell application "System Events" to set isAuth to ((title of theWindow) as string contains "auth")
	end try

	-- Если Home — определяем состояние и жмём Connect
	if not isAuth then
		-- Если в Home уже есть Disconnect-кнопка — VPN уже активен. Ничего не делаем!
		set disconnectElt to my findClickableByName(theWindow, kDisconnectNames)
		if disconnectElt is not missing value then return "alreadyConnected"

		-- Проверка: настроено ли хотя бы одно подключение (есть AXPopUpButton с непустым value)
		if not my hasConfiguredConnection(theWindow) then
			return "ERROR: в приложении не настроено ни одного подключения. Открой приложение вручную и добавь VPN-профиль (например, <your-vpn-url>)."
		end if

		set connectElt to my findClickableByName(theWindow, kConnectNames)
		if connectElt is missing value then
			return "ERROR: на Home-окне не найдено ни Connect, ни Disconnect — состояние неизвестно (запусти debug-inspect.applescript)"
		end if
		tell application "System Events" to click connectElt

		-- Ждём появления auth-окна (тот же процесс, изменится title)
		set waited to 0
		set authWindow to missing value
		repeat while waited < 25
			delay 0.5
			set waited to waited + 0.5
			set authWindow to my getAppWindowByTitleContains("auth")
			if authWindow is not missing value then exit repeat
			-- Sheet может появиться вместо auth (например, ошибка соединения)
			if (my findAnySheet()) is not missing value then
				my handleSheetIfAny(5)
			end if
		end repeat
		if authWindow is missing value then return "ERROR: auth-окно не появилось за 25с"
		set theWindow to authWindow
	end if

	-- Ждём появления secure-поля в auth-окне (форма грузится из веба).
	-- Важно: AppleScript reference `window N of process` это индекс, не объект.
	-- Если в процессе работы окна поменяются местами (Home станет frontmost),
	-- старый theWindow начнёт указывать НЕ на auth. Поэтому на каждой итерации
	-- получаем auth-окно заново по title.
	set passField to missing value
	set waited to 0
	repeat while waited < 15
		set authNow to my getAppWindowByTitleContains("auth")
		if authNow is not missing value then
			set passField to my findFirstSecureField(authNow)
			if passField is not missing value then
				set theWindow to authNow
				exit repeat
			end if
		end if
		delay 0.3
		set waited to waited + 0.3
	end repeat
	if passField is missing value then
		-- Намеренно НЕ фолбэчимся на обычное text field —
		-- пароль может попасть в видимое поле логина (plaintext в DOM).
		return "ERROR: AXSecureTextField не найден в auth-окне — fill.applescript нужно обновить (см. debug-inspect)"
	end if

	-- Активируем приложение и ЖДЁМ frontmost, иначе keystroke улетит в терминал
	tell application kAppName to activate
	if not my waitForFrontmost(2.5) then
		return "ERROR: Приложение не стало frontmost — пароль не введён ради безопасности"
	end if

	tell application "System Events"
		-- Реальный click (AXPress) переводит фокус и на AX-уровне, и в DOM WebView
		set focusedOk to false
		try
			click passField
			set focusedOk to true
		end try
		if not focusedOk then
			try
				perform action "AXPress" of passField
				set focusedOk to true
			end try
		end if
		if not focusedOk then
			try
				set focused of passField to true
				set focusedOk to true
			end try
		end if
		delay 0.4

		-- Перепроверяем frontmost — критически важно перед keystroke
		if not my waitForFrontmost(1.0) then
			return "ERROR: Приложение потеряло frontmost между click и keystroke"
		end if

		-- Очищаем поле и набираем пароль (cmd+A → ввод заменяет выделение)
		keystroke "a" using command down
		delay 0.1
		keystroke thePass
		delay 0.4

		-- Если поле осталось пустым — пробуем set value (часто не триггерит JS,
		-- но как страховка пусть будет)
		set currentLen to 0
		try
			set v to value of passField
			if v is not missing value then set currentLen to length of (v as string)
		end try
		if currentLen = 0 then
			try
				set value of passField to thePass
				delay 0.2
			end try
		end if
	end tell

	-- Submit. Получаем auth-окно заново — после keystroke Home мог стать frontmost
	-- и нумерация окон поменяться (window N это индекс, а не фиксированный объект).
	set authNow to my getAppWindowByTitleContains("auth")
	if authNow is missing value then
		-- auth уже закрылся — форма сабмитнулась сама (например, Enter в WebView)
		my handleSheetIfAny(25)
		return "ok"
	end if
	set submitElt to my findClickableByName(authNow, kSubmitNames)
	if submitElt is not missing value then
		try
			tell application "System Events" to click submitElt
		on error
			try
				tell application "System Events" to perform action "AXPress" of submitElt
			on error
				tell application kAppName to activate
				delay 0.2
				tell application "System Events" to keystroke return
			end try
		end try
	else
		-- Submit не найден — даём фокусу вернуться в auth и шлём Enter
		tell application kAppName to activate
		delay 0.2
		tell application "System Events" to keystroke return
	end if

	-- Дожидаемся и разруливаем sheet (Transfer Logon и т.п.)
	my handleSheetIfAny(25)

	return "ok"
end mainFlow
