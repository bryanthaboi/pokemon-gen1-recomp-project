LOCAL_PATH:= $(call my-dir)

# libogg
include $(CLEAR_VARS)

LOCAL_MODULE    := libmodplug
LOCAL_CFLAGS    := -fexceptions -g -Dlinux -DHAVE_GCC_DESTRUCTOR=1 -DOPT_GENERIC -DREAL_IS_FLOAT
LOCAL_CPPFLAGS  := ${LOCAL_CFLAGS}

LOCAL_C_INCLUDES := \
	${LOCAL_PATH} \
	${LOCAL_PATH}/src \
	${LOCAL_PATH}/src/libmodplug
LOCAL_EXPORT_C_INCLUDES := ${LOCAL_PATH}/src
LOCAL_SRC_FILES := \
	$(filter-out \
  , $(subst $(LOCAL_PATH)/,,\
	$(wildcard ${LOCAL_PATH}/src/*.cpp) ))

# $(info libmodplug: include dirs $(LOCAL_C_INCLUDES))
# $(info libmodplug: src files $(LOCAL_SRC_FILES))

include $(BUILD_STATIC_LIBRARY)
