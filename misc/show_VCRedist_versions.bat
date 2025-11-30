@echo off
setlocal EnableDelayedExpansion

REM Loop over 64-bit uninstall keys
for /f "tokens=*" %%K in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"') do (
    for /f "tokens=2,*" %%A in ('reg query "%%K" /v DisplayName 2^>nul ^| find "Visual C++"') do (
        set "NAME=%%B"
        for /f "tokens=2,*" %%X in ('reg query "%%K" /v DisplayVersion 2^>nul') do (
            set "VER=%%Y"
            echo !NAME! - Version: !VER!
        )
    )
)

REM Loop over 32-bit uninstall keys on 64-bit Windows
for /f "tokens=*" %%K in ('reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" 2^>nul') do (
    for /f "tokens=2,*" %%A in ('reg query "%%K" /v DisplayName 2^>nul ^| find "Visual C++"') do (
        set "NAME=%%B"
        for /f "tokens=2,*" %%X in ('reg query "%%K" /v DisplayVersion 2^>nul') do (
            set "VER=%%Y"
            echo !NAME! - Version: !VER!
        )
    )
)

exit /b 0
