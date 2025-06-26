@echo off
cd src\plugins
odin run . -vet -strict-style
IF %ERRORLEVEL% NEQ 0 exit /b 1
cd ..\..

odin build src -out:kzg.exe -collection:kzg=src -collection:plugins=plugins -debug
IF %ERRORLEVEL% NEQ 0 exit /b 1
