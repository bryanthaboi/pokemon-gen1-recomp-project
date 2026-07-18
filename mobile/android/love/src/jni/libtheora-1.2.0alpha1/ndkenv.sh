#
# This file is a modified version of the android build system of the
# Adventure Game Studio (AGS) https://github.com/adventuregamestudio/ags
#

export NDK_TOOLCHAIN=arm-linux-androideabi-4.8

unset DEVROOT SDKROOT CFLAGS CC LD CPP CXX AR AS NM CXXCPP RANLIB LDFLAGS CPPFLAGS CXXFLAGS

export NDK_PLATFORM_ROOT=$ANDROID_NDK/platforms/android-9/arch-arm
export NDK_PLATFORM_NAME=armeabi-v7a
export NDK_HOST_NAME=arm-linux-androideabi
export NDK_TOOLCHAIN_ROOT=$ANDROID_NDK/toolchains/$NDK_TOOLCHAIN/prebuilt/linux-x86_64
export PATH=$NDK_TOOLCHAIN_ROOT/bin:$PATH

export AR=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-ar
export AS=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-as
export ASCPP=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-as
export CC=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-gcc
export CPP="$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-cpp -E --sysroot=$NDK_PLATFORM_ROOT"
export CXX=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-g++
export CXXCPP=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-g++
export LD=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-ld
export NM=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-nm
export RANLIB=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-ranlib
export STRIP=$NDK_TOOLCHAIN_ROOT/bin/arm-linux-androideabi-strip

export NDK_CFLAGS=" -mthumb -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -I$ANDROID_NDK/platforms/android-9/arch-arm/usr/include/sys"
export NDK_LDFLAGS=" -march=armv7-a -Wl,--fix-cortex-a8"
