@echo off
cd /d "%~dp0"

echo Checking for changes...
git add .

git diff --cached --quiet
if %errorlevel%==0 (
    echo No changes to publish.
    pause
    exit /b
)

set /p msg="Describe your changes (press Enter to use 'Update content'): "
if "%msg%"=="" set msg=Update content

git commit -m "%msg%"

echo Pushing to GitHub...
git push

echo.
echo Done! Your site will update in about 5 minutes.
echo Visit: https://danrschley.github.io/Measurement-Experimentation-and-Causal-Inference-Workshop/
pause
