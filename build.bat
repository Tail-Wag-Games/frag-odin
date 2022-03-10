@echo off

if exist ".\thirdparty\getopt\getopt.lib" if exist ".\thirdparty\getopt\getoptd.lib" goto :GETOPT_CONTINUE
:GETOPT_BUILD
call .\thirdparty\getopt\build.bat
if NOT %ERRORLEVEL% == 0 goto :EOF
:GETOPT_CONTINUE
if exist ".\thirdparty\fcontext\fcontext.lib" if exist ".\thirdparty\fcontext\fcontextd.lib" goto :FCONTEXT_CONTINUE
:FCONTEXT_BUILD
call .\thirdparty\fcontext\build.bat
if NOT %ERRORLEVEL% == 0 goto :EOF
:FCONTEXT_CONTINUE
if exist ".\thirdparty\lockless\lockless.lib" if exist ".\thirdparty\lockless\locklessd.lib" goto :LOCKLESS_CONTINUE
:LOCKLESS_BUILD
call .\thirdparty\lockless\build.bat
if NOT %ERRORLEVEL% == 0 goto :EOF
:LOCKLESS_CONTINUE
if exist ".\thirdparty\cr\cr.lib" if exist ".\thirdparty\cr\crd.lib" goto :CR_CONTINUE
:CR_BUILD
call .\thirdparty\cr\build.bat
if NOT %ERRORLEVEL% == 0 goto :EOF
:CR_CONTINUE
if exist ".\thirdparty\cimgui\cimgui.lib" if exist ".\thirdparty\cimgui\cimguid.lib" goto :IMGUI_CONTINUE
:IMGUI
call .\thirdparty\cimgui\build.bat
if NOT %ERRORLEVEL% == 0 goto :EOF
:IMGUI_CONTINUE
@REM if exist ".\thirdparty\sokol\sokol.lib" if exist ".\thirdparty\sokol\sokold.lib" goto :SOKOL_CONTINUE
:SOKOL_BUILD
call .\thirdparty\sokol\build.bat
if NOT %ERRORLEVEL% == 0 goto :EOF
:SOKOL_CONTINUE
if exist ".\thirdparty\dmon\dmon.lib" if exist ".\thirdparty\dmon\dmond.lib" goto :DMON_CONTINUE
:DMON_BUILD
call .\thirdparty\sokol\build.bat
if NOT %ERRORLEVEL% == 0 goto :EOF
:DMON_CONTINUE
if exist ".\src\frag\gfx\shaders\basic.odin" if exist ".\src\frag\gfx\shaders\offscreen.odin" goto :GFX_SHADERS_CONTINUE
:GFX_SHADERS_BUILD
call thirdparty\glslcc\.build\src\Debug\glslcc.exe -r -l hlsl --cvar=offscreen -o ./src/frag/gfx/shaders/offscreen.odin --vert=./src/frag/gfx/offscreen.vert --frag=./src/frag/gfx/offscreen.frag
if NOT %ERRORLEVEL% == 0 goto :EOF
call thirdparty\glslcc\.build\src\Debug\glslcc.exe -r -l hlsl --cvar=basic -o ./src/frag/gfx/shaders/basic.odin --vert=./src/frag/gfx/basic.vert --frag=./src/frag/gfx/basic.frag
if NOT %ERRORLEVEL% == 0 goto :EOF
call thirdparty\glslcc\.build\src\Debug\glslcc.exe -r -l hlsl --cvar=wire -o ./src/3d/debug/shaders/wire.odin --vert=./src/3d/debug/wire.vert --frag=./src/3d/debug/wire.frag
if NOT %ERRORLEVEL% == 0 goto :EOF
:GFX_SHADERS_CONTINUE
call odin build src/frag/app/app.odin -debug -opt:0 -out:frag.exe -collection:frag=src/frag -collection:imgui=src/imgui -collection:three_d=src/3d -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
if NOT %ERRORLEVEL% == 0 goto :EOF
if exist ".\src\imgui\shaders\imgui.odin" goto :IMGUI_SHADERS_CONTINUE
:IMGUI_SHADERS_BUILD
call thirdparty\glslcc\.build\src\Debug\glslcc.exe -r -l hlsl --cvar=imgui -o ./src/imgui/shaders/imgui.odin --vert=./src/imgui/imgui.vert --frag=./src/imgui/imgui.frag
if NOT %ERRORLEVEL% == 0 goto :EOF
:IMGUI_SHADERS_CONTINUE
call odin build src/imgui/impl/imgui.odin -debug -opt:0 -build-mode:dll -out:imgui.dll -collection:frag=src/frag -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
if NOT %ERRORLEVEL% == 0 goto :EOF
@REM call odin build src/ecs/ecs.odin -debug -build-mode:dll -out:ecs.dll -collection:frag=src/frag -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
@REM if NOT %ERRORLEVEL% == 0 goto :EOF
@REM call odin build src/input/input.odin -debug -build-mode:dll -out:input.dll -collection:frag=src/frag -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
@REM if NOT %ERRORLEVEL% == 0 goto :EOF
call odin build src/3d/impl/3d.odin -debug -opt:0 -build-mode:dll -out:3d.dll -collection:frag=src/frag -collection:linchpin=src/linchpin -collection:thirdparty=thirdparty
if NOT %ERRORLEVEL% == 0 goto :EOF
:FRAG_RUN
frag.exe --run=%1 --asset-dir=%2
:EOF
