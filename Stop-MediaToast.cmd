@echo off
chcp 65001 >nul
for /f "usebackq delims=" %%p in ("%USERPROFILE%\MediaToast\toast.pid") do taskkill /PID %%p /F >nul 2>&1
echo Плашка остановлена.
timeout /t 2 >nul