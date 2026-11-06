@echo off
cd /d "C:\Users\HP\Desktop\USIM\SEM 7\Final Year Project II\edge_server"
for /f "tokens=5" %%a in ('netstat -aon ^| findstr /C:":5000 " ^| findstr "LISTENING"') do taskkill /F /PID %%a >nul 2>&1
start "" /min cmd /c "timeout /t 12 /nobreak >nul & start http://127.0.0.1:5000"
python edge_server.py
pause