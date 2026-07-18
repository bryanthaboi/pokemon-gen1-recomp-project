rem Build instruction assume using WSL.

rem Prerequisite:
rem * Android NDK r23 or later.
rem * GCC in WSL, with multilib.
rem * NDK path appended to %PATH% in Windows. (Protip: path %PATH%;<NDK_ROOT>\toolchains\llvm\prebuilt\windows-x86_64\bin)
rem * LuaJIT interpreter, either in Windows or WSL.

mkdir android\arm64-v8a
mkdir android\armeabi-v7a
mkdir android\x86
mkdir android\x86_64

rem Reset error level
type nul

rem Find LuaJIT
luajit -v
if "%ERRORLEVEL%" == "0" (
	set LUAJIT_INTERPRETER=luajit.exe
	goto :ljdetermined
)
wsl luajit -v
if "%ERRORLEVEL%" == "0" (
	set LUAJIT_INTERPRETER=luajit
	goto :ljdetermined
)
echo You need LuaJIT either in Windows or in WSL!
goto :error

:ljdetermined

rem ARMv8
call :compile arm64-v8a aarch64-linux-android 21
if "%ERRORLEVEL%" == "1" goto :error

rem ARMv7
call :compile armeabi-v7a armv7a-linux-androideabi 16 -m32
if not "%ERRORLEVEL%" == "0" goto :error

rem x86
call :compile x86 i686-linux-android 16 -m32
if not "%ERRORLEVEL%" == "0" goto :error

rem x86_64
call :compile x86_64 x86_64-linux-android 21
if not "%ERRORLEVEL%" == "0" goto :error

goto :done

:compile
if exist android\%1\libluajit.a exit /b 0
wsl make clean
if not "%ERRORLEVEL%" == "0" goto :error
wsl make ^
	HOST_LUA=%LUAJIT_INTERPRETER% ^
	"HOST_CC=gcc %4" ^
	HOST_CFLAGS=-D_CRT_SECURE_NO_WARNINGS ^
	CC=clang ^
	CROSS=%2- ^
	"STATIC_CC=%2%3-clang -fPIC" ^
	"DYNAMIC_CC=%2%3-clang -fPIC" ^
	"TARGET_AR=llvm-ar.exe rcus" ^
	TARGET_SYS=Linux ^
	TARGET_LD=%2%3-clang ^
	TARGET_LDFLAGS=-fuse-ld=lld ^
	TARGET_STRIP=llvm-strip.exe ^
	TARGET_SONAME=libluajit.so ^
	CCDEBUG=-g ^
	"GIT_RELVER=cp ../.relver luajit_relver.txt" ^
	amalg -j%NUMBER_OF_PROCESSORS%
if not "%ERRORLEVEL%" == "0" goto :error
copy src\libluajit.a android\%1\libluajit.a
if not "%ERRORLEVEL%" == "0" goto :error
copy src\libluajit.so android\%1\libluajit.so
if not "%ERRORLEVEL%" == "0" goto :error
copy src\luajit.h android\%1\luajit.h
if not "%ERRORLEVEL%" == "0" goto :error
xcopy src\jit android\%1\jit /I
if not "%ERRORLEVEL%" == "0" goto :error
del android\%1\jit\.gitignore
goto :done

:error
exit /b 1

:done
wsl make clean
exit /b 0
