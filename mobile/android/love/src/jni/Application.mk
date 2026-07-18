# Uncomment this if you're using STL in your project
# See CPLUSPLUS-SUPPORT.html in the NDK documentation for more information
# APP_STL := stlport_static 
APP_STL := c++_shared
APP_ABI := armeabi-v7a
APP_CPPFLAGS := -frtti
APP_LDFLAGS := -llog -landroid -lz -fuse-ld=lld
APP_PLATFORM := 10
NDK_TOOLCHAIN_VERSION := clang

# Fix for building on Windows
# http://stackoverflow.com/questions/12598933/ndk-build-createprocess-make-e-87-the-parameter-is-incorrect
APP_SHORT_COMMANDS := true

# APP_OPTIM := debug
