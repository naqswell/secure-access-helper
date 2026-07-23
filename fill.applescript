-- Автоподключение secure-access-helper.
-- Поток:
--   1) Окно Home — внутри WebView кнопка Connect (AXLink).
--   2) После клика появляется auth-форма (окно с AXSecureTextField внутри AXWebArea
--      и AXLink "Подтвердить") — заполняем пароль.
--   3) Если показывается sheet "Transfer Logon" — жмём Transfer.
--
-- Usage: osascript fill.applescript <account> [baseDir]
--   baseDir — каталог репозитория; из него берётся bin/setlayout для форса
--   латинской раскладки перед вводом пароля (иначе keystroke уходит мусором
--   под кириллицей). Если baseDir/хелпер недоступны — fallback на clipboard-paste.
-- Возвращает: "ok" / "alreadyConnected" / "windowNotAppeared" / "ERROR: <reason>"
--
-- ВАЖНО: успех коннекта здесь НЕ подтверждается — "ok" означает лишь «форму
-- отправили». Авторитетную проверку (scutil Connected) делает connect.sh.

property kAppName : "Citrix Secure Access"
property kKeychainService : "secure-access-helper"

-- Способ ввода пароля: "layout" (форс ASCII + keystroke, по умолчанию),
-- "clipboard" (Cmd+V), "keystroke" (как есть, с отказом под нелатинской раскладкой).
property kInjectMethod : "layout"

-- Защита от бесконечной рекурсии при обходе AX-дерева.
property kMaxAxDepth : 25
-- Потолок времени на один обход дерева (иначе зависший WebView вешал бы osascript).
property kAxTimeout : 8

property kConnectNames : {"Connect", "Подключиться", "Подключить"}
property kDisconnectNames : {"Log off", "Log Off", "Log out", "Log Out", "Sign off", "Sign Off", "Sign out", "Sign Out", "Disconnect", "Отключить", "Отключиться", "Выйти"}
property kSubmitNames : {"Подтвердить", "Submit", "Sign in", "Войти", "OK"}
property kTransferButtonNames : {"Transfer", "Передать", "Перенести"}

-- ---------- AX-обход (рекурсивный поиск, с ограничением по времени) ----------

on findFirstSecureField(rootElt)
	try
		with timeout of kAxTimeout seconds
			return my findFirstSecureFieldD(rootElt, 0)
		end timeout
	on error
		return missing value
	end try
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

on findClickableByName(rootElt, candidates)
	try
		with timeout of kAxTimeout seconds
			return my findClickableByNameD(rootElt, candidates, 0)
		end timeout
	on error
		return missing value
	end try
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

on findSheet(rootElt)
	try
		with timeout of kAxTimeout seconds
			return my findSheetD(rootElt, 0)
		end timeout
	on error
		return missing value
	end try
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

on collectStaticTexts(rootElt)
	try
		with timeout of kAxTimeout seconds
			return my collectStaticTextsD(rootElt, 0)
		end timeout
	on error
		return {}
	end try
end collectStaticTexts

on collectStaticTextsD(rootElt, depth)
	set res to {}
	if depth > kMaxAxDepth then return res
	tell application "System Events"
		try
			if (role of rootElt) is "AXStaticText" then
				try
					set v to value of rootElt
					if v is not missing value then set end of res to (v as string)
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
			set end of res to sR
		end repeat
	end repeat
	return res
end collectStaticTextsD

-- ---------- Окна приложения ----------

on getAppWindow()
	tell application "System Events"
		if not (exists process kAppName) then return missing value
		tell process kAppName
			if (count of windows) is 0 then return missing value
			return window 1
		end tell
	end tell
end getAppWindow

on windowHasSecureField(w)
	return (my findFirstSecureField(w)) is not missing value
end windowHasSecureField

-- Auth-окно ищем СТРУКТУРНО (по наличию AXSecureTextField), заголовок "auth" —
-- лишь запасная подсказка. Так флоу не ломается на другой локали/названии портала.
on getAuthWindow()
	tell application "System Events"
		if not (exists process kAppName) then return missing value
		tell process kAppName
			repeat with w in windows
				if my windowHasSecureField(w) then return w
			end repeat
			repeat with w in windows
				try
					if (title of w) as string contains "auth" then return w
				end try
			end repeat
		end tell
	end tell
	return missing value
end getAuthWindow

-- Проверяет, что в окне есть Connection-дропдаун с непустым host-подобным value.
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
						if v is not "" and (v contains "." or v contains ":" or v contains "/") then return true
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

-- ---------- Focus / frontmost / раскладка ----------

on waitForFrontmost(timeoutSec)
	-- Аккумулятор, НЕ (current date): у current date разрешение 1с, оно обрезает
	-- дробные таймауты (2.5 -> 2), а под-секундная фаза может схлопнуть «1.0с» почти
	-- в 0. Здесь per-iteration работа копеечная (один frontmost-чек), так что
	-- аккумулятор ждёт полную длительность и надёжен для дробных значений.
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

on isFocused(elt)
	try
		tell application "System Events"
			return (value of attribute "AXFocused" of elt) is true
		end tell
	end try
	return false
end isFocused

on fileExists(p)
	try
		do shell script "test -x " & quoted form of p
		return true
	end try
	return false
end fileExists

on captureFrontmostApp()
	try
		tell application "System Events"
			return name of first process whose frontmost is true
		end tell
	end try
	return missing value
end captureFrontmostApp

on restoreFocusTo(procName)
	if procName is missing value then return
	if procName is kAppName then return
	try
		tell application "System Events" to set frontmost of process procName to true
	end try
end restoreFocusTo

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

-- ---------- Ввод пароля (layout-safe) ----------

on typeSecret(passField, thePass)
	tell application "System Events"
		keystroke "a" using command down
		delay 0.1
		keystroke thePass
		delay 0.3
	end tell
end typeSecret

on typeSecretViaClipboard(passField, thePass)
	set prevClip to missing value
	try
		set prevClip to the clipboard
	end try
	try
		set the clipboard to thePass
		tell application "System Events"
			keystroke "a" using command down
			delay 0.1
			keystroke "v" using command down
			delay 0.3
		end tell
	end try
	-- буфер чистим/восстанавливаем как можно скорее
	try
		if prevClip is missing value then
			set the clipboard to ""
		else
			set the clipboard to prevClip
		end if
	end try
	return my verifyFieldFilled(passField, thePass)
end typeSecretViaClipboard

on verifyFieldFilled(passField, thePass)
	set currentLen to 0
	try
		tell application "System Events"
			set v to value of passField
			if v is not missing value then set currentLen to length of (v as string)
		end tell
	end try
	if currentLen is 0 then
		-- страховка на secure-поле (может не триггерить JS; connect.sh всё равно
		-- проверит реальный коннект через scutil).
		try
			tell application "System Events" to set value of passField to thePass
		end try
	end if
	return "ok"
end verifyFieldFilled

on activeLayoutIsNonLatin(baseDir)
	if baseDir is "" then return false
	set helper to baseDir & "/bin/setlayout"
	if not my fileExists(helper) then return false
	set cur to ""
	try
		set cur to do shell script quoted form of helper
	end try
	if cur contains "keylayout.ABC" or cur contains "keylayout.US" or cur contains "keylayout.British" or cur contains "keylayout.Australian" or cur contains "keylayout.Canadian" or cur contains "keylayout.Irish" then
		return false
	end if
	return true
end activeLayoutIsNonLatin

-- Ввод пароля с гарантиями: поле в фокусе + приложение frontmost ПРЯМО перед вводом.
on injectPassword(passField, thePass, baseDir)
	tell application "System Events"
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
		try
			set focused of passField to true
		end try
	end tell
	delay 0.3

	-- НЕ вводим пароль, пока не убедились, что фокус реально на secure-поле —
	-- иначе он мог бы уйти в видимое поле username (plaintext).
	if not my isFocused(passField) then
		return "ERROR: secure-поле не получило фокус — пароль не введён"
	end if
	-- и что приложение всё ещё frontmost — прямо перед вводом
	if not my waitForFrontmost(1.0) then
		return "ERROR: Приложение потеряло frontmost перед вводом пароля"
	end if

	set methodUsed to kInjectMethod

	if methodUsed is "layout" then
		set helper to ""
		if baseDir is not "" then set helper to baseDir & "/bin/setlayout"
		if helper is not "" and my fileExists(helper) then
			set prevSrc to ""
			try
				set prevSrc to do shell script quoted form of helper & " ASCII"
			end try
			set typed to false
			set errMsg to ""
			try
				-- ПРЯМО перед вводом: и frontmost, и фокус на secure-поле (не раньше:
				-- за время shell-out раскладки фокус мог перескочить на видимое поле).
				if my waitForFrontmost(1.0) and my isFocused(passField) then
					my typeSecret(passField, thePass)
					set typed to true
				else
					set errMsg to "ERROR: фокус/frontmost потерян перед вводом пароля"
				end if
			on error
				set errMsg to "ERROR: сбой ввода пароля"
			end try
			-- Раскладку возвращаем ВСЕГДА, на любом пути (даже если keystroke бросил
			-- исключение) — иначе система залипла бы на ASCII.
			if prevSrc is not "" then
				try
					do shell script quoted form of helper & " " & quoted form of prevSrc
				end try
			end if
			if typed then return my verifyFieldFilled(passField, thePass)
			if errMsg is "" then set errMsg to "ERROR: пароль не введён"
			return errMsg
		else
			set methodUsed to "clipboard"
		end if
	end if

	if methodUsed is "clipboard" then
		if not (my waitForFrontmost(1.0) and my isFocused(passField)) then
			return "ERROR: фокус/frontmost потерян перед вводом пароля"
		end if
		return my typeSecretViaClipboard(passField, thePass)
	end if

	-- keystroke как есть: под нелатинской раскладкой НЕ вводим (иначе мусор + лок аккаунта)
	if my activeLayoutIsNonLatin(baseDir) then
		return "ERROR: активна нелатинская раскладка — ввод пароля отложен"
	end if
	if not (my waitForFrontmost(1.0) and my isFocused(passField)) then
		return "ERROR: фокус/frontmost потерян перед вводом пароля"
	end if
	my typeSecret(passField, thePass)
	return my verifyFieldFilled(passField, thePass)
end injectPassword

-- ---------- Sheets ----------

-- Обрабатываем ТОЛЬКО положительно опознанный Transfer Logon. Незнакомые
-- диалоги (cert-trust, ошибки) НЕ подтверждаем вслепую — оставляем пользователю.
on handleSheetIfAny(timeoutSec)
	set deadline to (current date) + timeoutSec
	repeat while (current date) < deadline
		set sh to my findAnySheet()
		if sh is not missing value then
			set sheetText to ""
			try
				set texts to my collectStaticTexts(sh)
				repeat with t in texts
					set sheetText to sheetText & " " & t
				end repeat
			end try
			-- Опознаём Transfer Logon СТРУКТУРНО: по англ. тексту ИЛИ по наличию
			-- локализованной кнопки Transfer/Передать/Перенести. Незнакомые sheet'ы
			-- (cert-trust, ошибки) НЕ подтверждаем вслепую.
			set transferBtn to my findClickableByName(sh, kTransferButtonNames)
			set looksTransfer to (sheetText contains "Transfer Logon" or sheetText contains "logged on to the server from another")
			if transferBtn is not missing value or looksTransfer then
				if transferBtn is not missing value then
					try
						tell application "System Events" to click transferBtn
					on error
						try
							tell application "System Events" to perform action "AXPress" of transferBtn
						end try
					end try
					delay 1.0
					if (my findAnySheet()) is missing value then return true
				end if
			else
				-- незнакомый sheet — не трогаем
				return false
			end if
		end if
		delay 0.5
	end repeat
	return false
end handleSheetIfAny

-- ---------- Main ----------

on run argv
	set prevApp to my captureFrontmostApp()
	set baseDir to ""
	try
		if (count of argv) > 1 then set baseDir to item 2 of argv
	end try
	set outcome to my mainFlow(argv, baseDir)
	if outcome is "ok" or outcome is "alreadyConnected" then
		try
			my minimizeAllAppWindows()
		end try
	end if
	my restoreFocusTo(prevApp)
	return outcome
end run

on mainFlow(argv, baseDir)
	if (count of argv) < 1 then return "ERROR: account argument missing"
	set theAccount to item 1 of argv

	try
		set thePass to do shell script "security find-generic-password -a " & quoted form of theAccount & " -s " & quoted form of kKeychainService & " -w"
	on error errMsg
		return "ERROR: keychain access failed: " & errMsg
	end try

	tell application kAppName to activate

	-- забытый sheet с прошлой попытки — разрулить сразу
	my handleSheetIfAny(3)

	-- ждём появления окна (wall-clock)
	set theWindow to missing value
	set deadline to (current date) + 20
	repeat while (current date) < deadline
		set theWindow to my getAppWindow()
		if theWindow is not missing value then exit repeat
		delay 0.5
	end repeat
	if theWindow is missing value then return "windowNotAppeared"

	-- есть ли уже auth-окно (структурно)?
	set authWindow to my getAuthWindow()

	if authWindow is missing value then
		-- это Home. Уже подключены?
		set disconnectElt to my findClickableByName(theWindow, kDisconnectNames)
		if disconnectElt is not missing value then return "alreadyConnected"

		if not my hasConfiguredConnection(theWindow) then
			return "ERROR: в приложении не настроено ни одного подключения. Открой приложение вручную и добавь VPN-профиль."
		end if

		set connectElt to my findClickableByName(theWindow, kConnectNames)
		if connectElt is missing value then
			return "ERROR: на Home-окне не найдено ни Connect, ни Disconnect — состояние неизвестно (см. debug-inspect.applescript)"
		end if
		tell application "System Events" to click connectElt

		-- ждём auth-окно
		set deadline to (current date) + 25
		repeat while (current date) < deadline
			delay 0.5
			set authWindow to my getAuthWindow()
			if authWindow is not missing value then exit repeat
			if (my findAnySheet()) is not missing value then my handleSheetIfAny(5)
		end repeat
		if authWindow is missing value then return "ERROR: auth-окно не появилось за 25с"
	end if

	-- ждём secure-поле в auth-окне (форма грузится из веба). Окно берём заново по
	-- каждой итерации — индексы окон могли перетасоваться.
	set passField to missing value
	set deadline to (current date) + 15
	repeat while (current date) < deadline
		set authNow to my getAuthWindow()
		if authNow is not missing value then
			set passField to my findFirstSecureField(authNow)
			if passField is not missing value then exit repeat
		end if
		delay 0.3
	end repeat
	if passField is missing value then
		return "ERROR: AXSecureTextField не найден в auth-окне — обнови fill.applescript (см. debug-inspect)"
	end if

	-- фокус приложению и ждём frontmost, иначе keystroke улетит в терминал
	tell application kAppName to activate
	if not my waitForFrontmost(2.5) then
		return "ERROR: Приложение не стало frontmost — пароль не введён ради безопасности"
	end if

	set injRes to my injectPassword(passField, thePass, baseDir)
	if injRes is not "ok" then return injRes

	-- submit: окно берём заново
	set authNow to my getAuthWindow()
	if authNow is missing value then
		-- auth уже закрылся — форма ушла сама (Enter в WebView)
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
		tell application kAppName to activate
		delay 0.2
		tell application "System Events" to keystroke return
	end if

	my handleSheetIfAny(25)
	return "ok"
end mainFlow
