@echo off
cd /d C:\Users\china\Downloads\Notch-Triage-nlxxtw
if exist _rename.ps1 del _rename.ps1
if exist _rename2.ps1 del _rename2.ps1
git add -A
git reset HEAD -- .firecrawl ci-fail.zip ci-logs.zip fail-logs.zip fail-logs2.zip gh-artifacts.json gh-jobs.json gh-run.json job-logs.txt 2>nul
git status --short
git commit -m "Rebrand user-facing name from Notch Triage to BoringNotch-Next."
if errorlevel 1 exit /b 1
git push origin HEAD:main
if errorlevel 1 exit /b 1
git log -1 --oneline
