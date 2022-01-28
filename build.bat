@echo off

if exist ".\vendor\sokol\sokol.lib" if exist ".\vendor\sokol\sokold.lib" goto :CONTINUE
:SOKOL
call .\vendor\sokol\build.bat
:CONTINUE
if exist ".\vendor\deboost.context\fcontext.lib" if exist ".\vendor\deboost.context\fcontextd.lib" goto :CONTINUE
:SOKOL
call .\vendor\deboost.context\build.bat
:CONTINUE
odin build src/main.odin -out:frag.exe
frag %*