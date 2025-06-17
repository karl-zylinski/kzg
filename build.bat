@echo off
odin build src/renderer_d3d12 -build-mode:dll -collection:kzg=src -debug
IF %ERRORLEVEL% NEQ 0 exit /b 1

mkdir plugins
mkdir plugins\renderer_d3d12
copy renderer_d3d12.dll plugins\renderer_d3d12
copy renderer_d3d12.pdb plugins\renderer_d3d12
copy src\renderer_d3d12\api.odin plugins\renderer_d3d12

odin build src -out:kzg.exe -collection:kzg=src -collection:plugins=plugins -debug && kzg.exe
