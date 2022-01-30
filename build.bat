@echo off

if exist ".\thirdparty\sokol\sokol.lib" if exist ".\thirdparty\sokol\sokold.lib" goto :SOKOL_CONTINUE
:SOKOL_BUILD
call .\thirdparty\sokol\build.bat
:SOKOL_CONTINUE
if exist ".\thirdparty\deboost.context\fcontext.lib" if exist ".\thirdparty\deboost.context\fcontextd.lib" goto :FCONTEXT_CONTINUE
:FCONTEXT_BUILD
call .\thirdparty\deboost.context\build.bat
:FCONTEXT_CONTINUE
if exist ".\thirdparty\c89atomic\lockless.lib" if exist ".\thirdparty\c89atomic\locklessd.lib" goto :LOCKLESS_CONTINUE
:LOCKLESS_BUILD
call .\thirdparty\c89atomic\build.bat
:LOCKLESS_CONTINUE
call odin build src/frag/app/app.odin -debug -out:frag.exe -collection:frag=src/frag -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
if %ERRORLEVEL% == 0 goto :FRAG_RUN
goto :EOF
:FRAG_RUN
frag %*
:EOF
