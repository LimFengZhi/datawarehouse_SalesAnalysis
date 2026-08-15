@ECHO OFF
SETLOCAL
REM ===================================================================
REM load_all.bat  -  SQL*Loader batch load, parent tables first
REM
REM Usage:  load_all.bat username password connect_string [data_folder]
REM
REM   load_all.bat dwh mypass XE
REM       -> uses the sibling "data" folder automatically
REM
REM   load_all.bat dwh mypass XE "C:\some\other\csv_folder"
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

REM ---- default data folder = ..\data relative to this script ----
IF "%DATA%"=="" SET DATA=%~dp0..\data

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

ECHO Control files : %CTL%
ECHO CSV folder    : %DATA%
ECHO.

PUSHD "%DATA%"

FOR %%T IN (branch supplier product service branch_utils_category staff customer branch_expense salary_payment orders order_detail reservation reservation_detail purchase) DO (
    ECHO Loading %%T ...
    sqlldr %U%/%P%@%DB% control="%CTL%%%T.ctl" log="%CTL%%%T.log" rows=5000
    IF ERRORLEVEL 1 ECHO    *** %%T reported errors - check %%T.log
)

POPD

ECHO.
ECHO Done. Logs are in %CTL%
ECHO Check each .log for "Rows successfully loaded".
ECHO Rejected rows (if any) land in .bad files in %DATA%
PAUSE
