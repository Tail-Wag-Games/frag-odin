@echo off

if exist ".\vendor\sokol\sokol.lib" if exist ".\vendor\sokol\sokold.lib" goto :SOKOL_CONTINUE
:SOKOL_BUILD
call .\vendor\sokol\build.bat
:SOKOL_CONTINUE
if exist ".\vendor\deboost.context\fcontext.lib" if exist ".\vendor\deboost.context\fcontextd.lib" goto :FCONTEXT_CONTINUE
:FCONTEXT_BUILD
call .\vendor\deboost.context\build.bat
:FCONTEXT_CONTINUE
call odin build src/main.odin -out:frag.exe
if %ERRORLEVEL% == 0 goto :FRAG_BUILD
goto :EOF
:FRAG_BUILD
frag %*
:EOF
