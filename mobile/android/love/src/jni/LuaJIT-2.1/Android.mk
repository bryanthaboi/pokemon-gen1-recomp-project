LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE := libluajit
LOCAL_SRC_FILES := android/$(TARGET_ARCH_ABI)/libluajit.a
LOCAL_EXPORT_C_INCLUDES := ${LOCAL_PATH}/src ${LOCAL_PATH}/android/$(TARGET_ARCH_ABI)

include $(PREBUILT_STATIC_LIBRARY)
