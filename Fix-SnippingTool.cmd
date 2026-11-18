@echo off
chcp 65001 >nul
taskkill /IM SnippingTool.exe /F >nul 2>&1
timeout /t 1 >nul
echo Ножницы перезапущены. Win+Shift+S снова работает.
timeout /t 3 >nul