LOCAL_PATH:= $(call my-dir)

# libogg
include $(CLEAR_VARS)

LOCAL_MODULE    := libmpg123
LOCAL_CFLAGS    := -fexceptions -g -Dlinux -DHAVE_GCC_DESTRUCTOR=1 -DOPT_GENERIC -DREAL_IS_FLOAT
LOCAL_CPPFLAGS  := ${LOCAL_CFLAGS}

LOCAL_C_INCLUDES := ${LOCAL_PATH}/src
LOCAL_EXPORT_C_INCLUDES := ${LOCAL_PATH}/src/libmpg123
LOCAL_SRC_FILES := \
	$(filter-out \
	  src/libmpg123/dct64_altivec.c \
		src/libmpg123/dct64_i386.c src/libmpg123/dct64_i486.c \
		src/libmpg123/synth_altivec.c src/libmpg123/synth_i486.c \
		src/libmpg123/synth_real.c \
    src/libmpg123/synth_s32.c \
		src/libmpg123/lfs_wrap.c \
		src/libmpg123/testcpu.c \
  , $(subst $(LOCAL_PATH)/,,\
	$(wildcard ${LOCAL_PATH}/src/libmpg123/*.c) ))

# $(info libmpg123: include dirs $(LOCAL_C_INCLUDES))
# $(info libmpg123: src files $(LOCAL_SRC_FILES))

include $(BUILD_SHARED_LIBRARY)
