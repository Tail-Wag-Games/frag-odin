@echo off

if exist ".\thirdparty\getopt\getopt.lib" if exist ".\thirdparty\getopt\getoptd.lib" goto :GETOPT_CONTINUE
:GETOPT_BUILD
call .\thirdparty\getopt\build.bat
:GETOPT_CONTINUE
if exist ".\thirdparty\fcontext\fcontext.lib" if exist ".\thirdparty\fcontext\fcontextd.lib" goto :FCONTEXT_CONTINUE
:FCONTEXT_BUILD
call .\thirdparty\fcontext\build.bat
:FCONTEXT_CONTINUE
if exist ".\thirdparty\lockless\lockless.lib" if exist ".\thirdparty\lockless\locklessd.lib" goto :LOCKLESS_CONTINUE
:LOCKLESS_BUILD
call .\thirdparty\lockless\build.bat
:LOCKLESS_CONTINUE
if exist ".\thirdparty\cr\cr.lib" if exist ".\thirdparty\cr\crd.lib" goto :CR_CONTINUE
:CR_BUILD
call .\thirdparty\cr\build.bat
:CR_CONTINUE
if exist ".\thirdparty\cimgui\cimgui.lib" if exist ".\thirdparty\cimgui\cimguid.lib" goto :IMGUI_CONTINUE
:IMGUI
call .\thirdparty\cimgui\build.bat
:IMGUI_CONTINUE
if exist ".\thirdparty\sokol\sokol.lib" if exist ".\thirdparty\sokol\sokold.lib" goto :SOKOL_CONTINUE
:SOKOL_BUILD
call .\thirdparty\sokol\build.bat
:SOKOL_CONTINUE
if exist ".\thirdparty\dmon\dmon.lib" if exist ".\thirdparty\dmon\dmond.lib" goto :DMON_CONTINUE
:DMON_BUILD
call .\thirdparty\sokol\build.bat
:DMON_CONTINUE
call odin build src/frag/app/app.odin -debug -out:frag.exe -collection:frag=src/frag -collection:imgui=src/imgui -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
if NOT %ERRORLEVEL% == 0 goto :EOF
call thirdparty\glslcc\.build\src\Debug\glslcc.exe -l hlsl --cvar=imgui -o ./src/imgui/shaders/imgui.odin --vert=./src/imgui/imgui.vert -r --frag=./src/imgui/imgui.frag
call odin build src/imgui/imgui.odin -debug -build-mode:dll -out:imgui.dll -collection:frag=src/frag -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
if NOT %ERRORLEVEL% == 0 goto :EOF
call odin build src/ecs/ecs.odin -debug -build-mode:dll -out:ecs.dll -collection:frag=src/frag -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
if NOT %ERRORLEVEL% == 0 goto :EOF
:FRAG_RUN
frag %*
:EOF
