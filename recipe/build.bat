@echo on
setlocal

rem Put the m2-* (MSYS2) userland first on PATH so configure/make run in a
rem POSIX environment; zig.exe from the build env stays reachable as well.
set "PATH=%BUILD_PREFIX%\Library\usr\bin;%PATH%"
set "MSYSTEM=MSYS"
set "CHERE_INVOKING=1"

bash -e "%RECIPE_DIR%\build.sh"
if errorlevel 1 exit /b 1
