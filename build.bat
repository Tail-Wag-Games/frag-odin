@echo off

if exist ".\vendor\sokol\sokol_app\sokol_app_d3d11.lib" if exist ".\vendor\sokol\sokol_gfx\sokol_gfx_d3d11.lib" goto :CONTINUE
:DEPS
call .\vendor\sokol\build.bat
:CONTINUE
odin build src/main.odin -out:frag.exe
frag %*