@echo off
rem Launch the Distant Horizon client. Extra args pass through to godot,
rem e.g.: run.bat -- --username=you --password=pw
set "PATH=%USERPROFILE%\scoop\shims;%PATH%"
godot --path "%~dp0" %*
