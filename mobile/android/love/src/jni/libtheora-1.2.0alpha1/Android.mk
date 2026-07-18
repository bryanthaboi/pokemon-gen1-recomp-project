LOCAL_PATH:= $(call my-dir)
include $(CLEAR_VARS)

LOCAL_MODULE := libtheora
LOCAL_CFLAGS := -g -Wno-parentheses

LOCAL_C_INCLUDES := \
	${LOCAL_PATH}/include \
	${LOCAL_PATh}/lib \
	${LOCAL_PATH}/../libogg-1.3.2/include
LOCAL_EXPORT_C_INCLUDES := ${LOCAL_PATH}/include
LOCAL_SRC_FILES := \
	lib/apiwrapper.c \
	lib/bitpack.c \
	lib/decapiwrapper.c \
	lib/decinfo.c \
	lib/decode.c \
	lib/dequant.c \
	lib/fragment.c \
	lib/huffdec.c \
	lib/idct.c \
	lib/info.c \
	lib/internal.c \
	lib/quant.c \
	lib/state.c \
	lib/encoder_disabled.c

LOCAL_ARM_NEON := true

LOCAL_STATIC_LIBRARIES := libogg

include $(BUILD_STATIC_LIBRARY)
