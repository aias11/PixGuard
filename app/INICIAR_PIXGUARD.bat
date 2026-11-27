@echo off
title PixGuard - servidor
echo.
echo  PixGuard - prototipo A3
echo  Digite o usuario e a senha do MySQL. O navegador abre sozinho.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0servidor.ps1"
pause
