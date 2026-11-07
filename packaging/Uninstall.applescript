-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 KC2RGW Chris
--
-- Uninstall PatchPrimeMac: asks, then runs uninstall.sh (in this app's Resources) as
-- an administrator. Built into "Uninstall PatchPrimeMac.app" by make-release.sh.

set here to POSIX path of (path to me)
set uninstaller to here & "Contents/Resources/uninstall.sh"
set question to "Remove PatchPrimeMac from this Mac?" & return & return & ¬
	"This removes the app, its audio engine and its driver, and puts your default sound input and output back. All sound on the Mac stops for a moment while macOS's audio restarts: turn loud speakers down first." & return & return & ¬
	"Keep your settings, presets and scenes, in case you install it again?"
set choice to button returned of (display dialog question with title "Uninstall PatchPrimeMac" ¬
	buttons {"Cancel", "Delete Everything", "Keep My Settings"} default button "Keep My Settings" ¬
	cancel button "Cancel" with icon caution)
set options to ""
if choice is "Delete Everything" then set options to " --delete-settings"
try
	set report to do shell script "/bin/bash " & quoted form of uninstaller & " --user " & ¬
		quoted form of (short user name of (system info)) & options with administrator privileges
	set lastLines to paragraphs -3 thru -1 of report
	set AppleScript's text item delimiters to return
	display dialog (lastLines as text) with title "Uninstall PatchPrimeMac" buttons {"OK"} default button "OK"
on error errorText number errorNumber
	if errorNumber is not -128 then display dialog "Uninstalling stopped: " & errorText with title "Uninstall PatchPrimeMac" buttons {"OK"} default button "OK" with icon stop
end try
