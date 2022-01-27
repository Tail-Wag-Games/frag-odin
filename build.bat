@echo off

if exist ".\vendor\sokol\sokol.lib" if exist ".\vendor\sokol\sokold.lib" goto :CONTINUE
:DEPS
call .\vendor\sokol\build.bat
:CONTINUE
odin build src/main.odin -out:frag.exe
frag %*