LOCAL_PATH:= $(call my-dir)

# libvorbis
include $(CLEAR_VARS)

LOCAL_MODULE    := libvorbis
LOCAL_CFLAGS    := -fexceptions -g -Dlinux -DHAVE_GCC_DESTRUCTOR=1 -DOPT_GENERIC -DREAL_IS_FLOAT
LOCAL_CPPFLAGS  := ${LOCAL_CFLAGS}

LOCAL_C_INCLUDES := ${LOCAL_PATH}/include
LOCAL_EXPORT_C_INCLUDES := ${LOCAL_C_INCLUDES}
		
LOCAL_SRC_FILES := \
	$(filter-out lib/psytune.c lib/vorbisenc.c, $(subst $(LOCAL_PATH)/,,\
	$(wildcard ${LOCAL_PATH}/lib/*.c) ))

# $(info libvorbis: include dirs $(LOCAL_C_INCLUDES))
# $(info libvorbis: src files $(LOCAL_SRC_FILES))

LOCAL_STATIC_LIBRARIES := libogg

include $(BUILD_STATIC_LIBRARY)
