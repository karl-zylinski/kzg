@echo off
cd src\plugins
odin run . -vet -strict-style
IF %ERRORLEVEL% NEQ 0 exit /b 1
cd ..\..

mkdir plugins
mkdir plugins\renderer_d3d12
copy src\plugins\renderer_d3d12\bin\renderer_d3d12.dll plugins\renderer_d3d12
copy src\plugins\renderer_d3d12\bin\renderer_d3d12.pdb plugins\renderer_d3d12
copy src\plugins\renderer_d3d12\api.odin plugins\renderer_d3d12

odin build src -out:kzg.exe -collection:kzg=src -collection:plugins=plugins -debug
IF %ERRORLEVEL% NEQ 0 exit /b 1
