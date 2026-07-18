#!/bin/bash
#
# This file is a modified version of the android build system of the
# Adventure Game Studio (AGS) https://github.com/adventuregamestudio/ags
#

set -e 

source ./ndkenv.sh

BUILD_DIR=build
rm -rf $BUILD_DIR
mkdir $BUILD_DIR
cp ../src/* -a $BUILD_DIR

export CFLAGS="$NDK_CFLAGS -fsigned-char --sysroot=$NDK_PLATFORM_ROOT"
export LDFLAGS="$NDK_LDFLAGS"

pushd $BUILD_DIR

# disable asflag-probe as it guess wrong arm arch
./autogen.sh --host=$NDK_HOST_NAME --disable-doc --disable-examples --disable-asflag-probe --disable-encode --disable-shared --disable-spec --disable-oggtest --disable-vorbistest

popd
