-- Рекурсивный дамп AX-дерева окон целевого приложения.
-- Запусти когда auth-окно открыто:
--   osascript ~/Projects/secure-access-helper/debug-inspect.applescript > ~/axdump.txt 2>&1

property maxDepth : 25

on padFor(d)
	set pad to ""
	repeat d times
		set pad to pad & "  "
	end repeat
	return pad
end padFor

on dumpElement(elt, depth, prefix)
	if depth > maxDepth then return ""
	set pad to my padFor(depth)

	set r to "?"
	try
		tell application "System Events" to set r to (role of elt) as string
	end try
	set sr to ""
	try
		tell application "System Events" to set sr to (subrole of elt) as string
	end try
	set nm to ""
	try
		tell application "System Events"
			set v to name of elt
			if v is not missing value then set nm to v as string
		end tell
	end try
	set dsc to ""
	try
		tell application "System Events"
			set v to description of elt
			if v is not missing value then set dsc to v as string
		end tell
	end try
	set val to ""
	try
		tell application "System Events"
			set v to value of elt
			if v is not missing value then set val to v as string
		end tell
	end try
	set hlp to ""
	try
		tell application "System Events" to set hlp to (value of attribute "AXHelp" of elt) as string
	end try
	set rid to ""
	try
		tell application "System Events" to set rid to (value of attribute "AXIdentifier" of elt) as string
	end try

	set txt to pad & prefix & "role=" & r
	if sr is not "" then set txt to txt & " subrole=" & sr
	if nm is not "" then set txt to txt & " name=" & nm
	if dsc is not "" then set txt to txt & " desc=" & dsc
	if val is not "" and length of val < 80 then set txt to txt & " value=" & val
	if hlp is not "" then set txt to txt & " help=" & hlp
	if rid is not "" then set txt to txt & " id=" & rid
	set txt to txt & linefeed

	set kids to {}
	try
		tell application "System Events" to set kids to UI elements of elt
	end try

	if (count of kids) > 0 then
		repeat with i from 1 to count of kids
			set txt to txt & my dumpElement(item i of kids, depth + 1, "[" & i & "] ")
		end repeat
	end if

	return txt
end dumpElement

on run
	set out to ""
	tell application "System Events"
		set targetProcs to (every process whose name contains "Secure Access")
	end tell
	repeat with p in targetProcs
		set pname to ""
		try
			tell application "System Events" to set pname to (name of p) as string
		end try
		set wins to {}
		try
			tell application "System Events" to set wins to windows of p
		end try
		repeat with i from 1 to count of wins
			set w to item i of wins
			set wt to ""
			try
				tell application "System Events" to set wt to (title of w) as string
			end try
			set out to out & "===== " & pname & " / window " & i & " / title=" & wt & " =====" & linefeed
			set out to out & my dumpElement(w, 0, "")
			set out to out & linefeed
		end repeat
	end repeat
	return out
end run
