-- Mark Dropout — instrument 8. Appends "<ts>\tmark\tstreamdeck" to the active
-- stream-mode session's marks.log (~/stream-logs/current, falling back to
-- today's directory) and shows a notification. Build with build-mark-dropout.zsh,
-- then bind ~/Applications/Mark Dropout.app to a Stream Deck "System → Open" action.
on run
	set logRoot to POSIX path of (path to home folder) & "stream-logs/"
	set stamp to do shell script "d=" & quoted form of logRoot & "current; [ -d \"$d\" ] || d=" & quoted form of logRoot & "$(date +%F); mkdir -p \"$d\"; t=$(date '+%Y-%m-%dT%H:%M:%S%z'); printf '%s\\tmark\\tstreamdeck\\n' \"$t\" >> \"$d/marks.log\"; printf '%s' \"$t\""
	display notification "dropout marked " & stamp with title "stream-mode"
end run
