// This file is NOT part of OpenAL-soft

#include <jni.h>

#include "oboe/Oboe.h"

extern "C"
{

JNIEXPORT void JNICALL
Java_org_love2d_android_GameActivity_nativeSetDefaultStreamValues(
    JNIEnv *env,
    jclass type,
    jint sampleRate,
    jint framesPerBurst
) {
    oboe::DefaultStreamValues::SampleRate = (int32_t) sampleRate;
    oboe::DefaultStreamValues::FramesPerBurst = (int32_t) framesPerBurst;
}

}
