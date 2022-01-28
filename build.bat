@echo off

if exist ".\vendor\sokol\sokol.lib" if exist ".\vendor\sokol\sokold.lib" goto :SOKOL_CONTINUE
:SOKOL_BUILD
call .\vendor\sokol\build.bat
:SOKOL_CONTINUE
if exist ".\vendor\deboost.context\fcontext.lib" if exist ".\vendor\deboost.context\fcontextd.lib" goto :FCONTEXT_CONTINUE
:FCONTEXT_BUILD
call .\vendor\deboost.context\build.bat
:FCONTEXT_CONTINUE
odin build src/main.odin -out:frag.exe
frag %*