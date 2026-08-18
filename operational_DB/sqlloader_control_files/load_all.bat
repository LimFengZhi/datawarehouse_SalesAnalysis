@ECHO OFF
SETLOCAL
REM ===================================================================
REM load_all.bat  -  SQL*Loader batch load, parent tables first
REM
REM Usage:  load_all.bat username password connect_string [data_folder]
REM
REM   load_all.bat dwh mypass XE
REM       -> uses ..\..\sales_data3\data18_21 automatically
REM
REM   load_all.bat dwh mypass XE "C:\...\sales_data3\data22_23"
REM       -> uses the folder you name
REM
REM Run this from ANY directory. It finds its own .ctl files via %~dp0
REM and switches into the CSV folder so the INFILE names inside each
REM .ctl resolve correctly.  Logs are written next to this script.
REM ===================================================================
SET U=%1
SET P=%2
SET DB=%3
SET DATA=%~4

REM ---- control files live in this script's own folder (has trailing \) ----
SET CTL=%~dp0

REM ---- default data folder, relative to this script:
REM ---- operational_DB\sqlloader_control_files\ -> sales_data3\data18_21 ----
IF "%DATA%"=="" SET DATA=%~dp0..\..\sales_data3\data18_21

IF "%DB%"=="" (
    ECHO Usage: load_all.bat username password connect_string [data_folder]
    ECHO Example: load_all.bat dwh mypass XE
    EXIT /B 1
)

IF NOT EXIST "%DATA%\branch.csv" (
    ECHO ERROR: branch.csv not found in "%DATA%"
    ECHO Point the 4th argument at the folder holding the CSV files.
    EXIT /B 1
)

REM ---- folder NAME only, e.g. "data2". A trailing backslash would make
REM ---- %%~nxI come back empty, so strip it first.
IF "%DATA:~-1%"=="\" SET DATA=%DATA:~0,-1%
FOR %%I IN ("%DATA%") DO SET DNAME=%%~nxI

ECHO Control files : %CTL%
ECHO CSV folder    : %DATA%
ECHO Log suffix    : _%DNAME%
ECHO.

PUSHD "%DATA%"

FOR %%T IN (branch supplier product service branch_utils_category staff customer branch_expense salary_payment orders order_detail reservation reservation_detail purchase) DO (
    ECHO Loading %%T ...
    REM SQL*Loader only WRITES a .bad when a row is rejected - it never
    REM clears an old one. Delete it first, so a .bad existing after
    REM this run always means THIS run rejected rows.
    IF EXIST "%%T.bad" DEL /Q "%%T.bad"
    sqlldr %U%/%P%@%DB% control="%CTL%%%T.ctl" log="%CTL%%%T_%DNAME%.log" rows=5000
    IF ERRORLEVEL 1 ECHO    *** %%T reported errors - check %%T_%DNAME%.log
)

POPD

ECHO.
ECHO Done. Logs are in %CTL%
ECHO   named ^<table^>_%DNAME%.log, so loading another folder does not
ECHO   overwrite this run's logs.
ECHO Check each for "Rows successfully loaded".
ECHO Rejected rows (if any) land in .bad files in %DATA%
ECHO   - no .bad file means nothing was rejected.
PAUSE
