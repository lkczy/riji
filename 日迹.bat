@echo off
rem Double-click to start myDiary.
rem Uses %~dp0 (this file's own folder) instead of a hard-coded path,
rem so the whole project folder can be moved anywhere and still work.
rem
rem The app is not a single .exe: my_diary.exe needs flutter_windows.dll
rem and the data\ folder sitting next to it, so it cannot be copied out alone.
start "" "%~dp0build\windows\x64\runner\Release\my_diary.exe"
