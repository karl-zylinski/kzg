@echo off
odin build src/renderer_d3d12 -build-mode:dll -collection:kzg=src -debug
odin run src -out:kzg.exe -collection:kzg=src -debug -keep-executable