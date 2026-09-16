@echo off
setlocal
cd /d "%~dp0"
title PDF Combiner

set "VENV_PY=%~dp0.venv\Scripts\python.exe"

if not exist "%VENV_PY%" (
    echo.
    echo  PDF Combiner - first-time setup
    echo  --------------------------------
    echo  Creating the local environment. This only happens once.
    echo.

    where py >nul 2>nul
    if not errorlevel 1 (
        py -3 -m venv "%~dp0.venv"
    ) else (
        where python >nul 2>nul
        if errorlevel 1 goto no_python
        python -m venv "%~dp0.venv"
    )

    if not exist "%VENV_PY%" goto setup_failed
)

"%VENV_PY%" -c "import flask, pikepdf, pypdf, reportlab" >nul 2>nul
if errorlevel 1 (
    echo.
    echo  Installing PDF Combiner components. This only happens once...
    "%VENV_PY%" -m pip install --disable-pip-version-check -r "%~dp0requirements.txt"
    if errorlevel 1 goto install_failed
)

echo.
echo  Starting PDF Combiner...
echo  Keep this window open while you use the app.
echo  Close this window when you are finished.
echo.

"%VENV_PY%" "%~dp0launcher.py" %*
if errorlevel 1 goto launch_failed
exit /b 0

:no_python
echo.
echo  PDF Combiner needs Python 3.10 or newer, but Python was not found.
echo  Install Python from https://www.python.org/downloads/windows/
echo  Then double-click this file again.
echo.
pause
exit /b 1

:setup_failed
echo.
echo  The local environment could not be created.
echo  Check that Python 3.10 or newer is installed, then try again.
echo.
pause
exit /b 1

:install_failed
echo.
echo  The required components could not be installed.
echo  Check your internet connection and double-click this file again.
echo.
pause
exit /b 1

:launch_failed
echo.
echo  PDF Combiner stopped because of an error shown above.
echo.
pause
exit /b 1
