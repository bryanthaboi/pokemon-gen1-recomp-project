LOVE_JNI_DIR := $(call my-dir)

ifeq ($(OS),Windows_NT)
    SHELL_EXECUTOR := powershell -executionpolicy unrestricted
    SCRIPT_EXTENSION := ps1
else
    SHELL_EXECUTOR := sh
    SCRIPT_EXTENSION := sh
endif

IS_NDK_R17 := $(shell ${SHELL_EXECUTOR} ${LOVE_JNI_DIR}/detect_ndkrel.${SCRIPT_EXTENSION} $(NDK_ROOT)/source.properties 17)
IS_ANDROID_21 := $(shell ${SHELL_EXECUTOR} ${LOVE_JNI_DIR}/detect_androidapi.${SCRIPT_EXTENSION} $(TARGET_PLATFORM) 21)
HAS_LOVE := $(shell ${SHELL_EXECUTOR} ${LOVE_JNI_DIR}/detect_love.${SCRIPT_EXTENSION} ${LOVE_JNI_DIR})

ifneq (${HAS_LOVE},yes)
    $(error Missing LOVE. Make sure to initialize the submodule correctly!)
endif

include $(call all-subdir-makefiles)
