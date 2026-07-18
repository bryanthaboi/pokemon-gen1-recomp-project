/*
 * An example showing how to play a stream sync'd to video, using ffmpeg.
 *
 * Requires C++14.
 */

#include <condition_variable>
#include <functional>
#include <algorithm>
#include <iostream>
#include <utility>
#include <iomanip>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <array>
#include <cmath>
#include <deque>
#include <mutex>
#include <ratio>

extern "C" {
#ifdef __GNUC__
_Pragma("GCC diagnostic push")
_Pragma("GCC diagnostic ignored \"-Wconversion\"")
_Pragma("GCC diagnostic ignored \"-Wold-style-cast\"")
#endif
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavformat/version.h"
#include "libavutil/avutil.h"
#include "libavutil/error.h"
#include "libavutil/frame.h"
#include "libavutil/mem.h"
#include "libavutil/pixfmt.h"
#include "libavutil/rational.h"
#include "libavutil/samplefmt.h"
#include "libavutil/time.h"
#include "libavutil/version.h"
#include "libavutil/channel_layout.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"

constexpr auto AVNoPtsValue = AV_NOPTS_VALUE;
constexpr auto AVErrorEOF = AVERROR_EOF;

struct SwsContext;
#ifdef __GNUC__
_Pragma("GCC diagnostic pop")
#endif
}

#include "SDL.h"

#include "AL/alc.h"
#include "AL/al.h"
#include "AL/alext.h"

#include "common/alhelpers.h"

extern "C" {
/* Undefine this to disable use of experimental extensions. Don't use for
 * production code! Interfaces and behavior may change prior to being
 * finalized.
 */
#define ALLOW_EXPERIMENTAL_EXTS

#ifdef ALLOW_EXPERIMENTAL_EXTS
#ifndef AL_SOFT_callback_buffer
#define AL_SOFT_callback_buffer
typedef unsigned int ALbitfieldSOFT;
#define AL_BUFFER_CALLBACK_FUNCTION_SOFT         0x19A0
#define AL_BUFFER_CALLBACK_USER_PARAM_SOFT       0x19A1
typedef ALsizei (AL_APIENTRY*LPALBUFFERCALLBACKTYPESOFT)(ALvoid *userptr, ALvoid *sampledata, ALsizei numsamples);
typedef void (AL_APIENTRY*LPALBUFFERCALLBACKSOFT)(ALuint buffer, ALenum format, ALsizei freq, LPALBUFFERCALLBACKTYPESOFT callback, ALvoid *userptr, ALbitfieldSOFT flags);
typedef void (AL_APIENTRY*LPALGETBUFFERPTRSOFT)(ALuint buffer, ALenum param, ALvoid **value);
typedef void (AL_APIENTRY*LPALGETBUFFER3PTRSOFT)(ALuint buffer, ALenum param, ALvoid **value1, ALvoid **value2, ALvoid **value3);
typedef void (AL_APIENTRY*LPALGETBUFFERPTRVSOFT)(ALuint buffer, ALenum param, ALvoid **values);
#endif
#endif /* ALLOW_EXPERIMENTAL_EXTS */
}

namespace {

inline constexpr int64_t operator "" _i64(unsigned long long int n) noexcept { return static_cast<int64_t>(n); }

#ifndef M_PI
#define M_PI (3.14159265358979323846)
#endif

using fixed32 = std::chrono::duration<int64_t,std::ratio<1,(1_i64<<32)>>;
using nanoseconds = std::chrono::nanoseconds;
using microseconds = std::chrono::microseconds;
using milliseconds = std::chrono::milliseconds;
using seconds = std::chrono::seconds;
using seconds_d64 = std::chrono::duration<double>;
using std::chrono::duration_cast;

const std::string AppName{"alffplay"};

ALenum DirectOutMode{AL_FALSE};
bool EnableWideStereo{false};
bool DisableVideo{false};
LPALGETSOURCEI64VSOFT alGetSourcei64vSOFT;
LPALCGETINTEGER64VSOFT alcGetInteger64vSOFT;

#ifdef AL_SOFT_events
LPALEVENTCONTROLSOFT alEventControlSOFT;
LPALEVENTCALLBACKSOFT alEventCallbackSOFT;
#endif

#ifdef AL_SOFT_callback_buffer
LPALBUFFERCALLBACKSOFT alBufferCallbackSOFT;
#endif

const seconds AVNoSyncThreshold{10};

#define VIDEO_PICTURE_QUEUE_SIZE 24

const seconds_d64 AudioSyncThreshold{0.03};
const milliseconds AudioSampleCorrectionMax{50};
/* Averaging filter coefficient for audio sync. */
#define AUDIO_DIFF_AVG_NB 20
const double AudioAvgFilterCoeff{std::pow(0.01, 1.0/AUDIO_DIFF_AVG_NB)};
/* Per-buffer size, in time */
constexpr milliseconds AudioBufferTime{20};
/* Buffer total size, in time (should be divisible by the buffer time) */
constexpr milliseconds AudioBufferTotalTime{800};
constexpr auto AudioBufferCount = AudioBufferTotalTime / AudioBufferTime;

enum {
    FF_MOVIE_DONE_EVENT = SDL_USEREVENT
};

enum class SyncMaster {
    Audio,
    Video,
    External,

    Default = External
};


inline microseconds get_avtime()
{ return microseconds{av_gettime()}; }

/* Define unique_ptrs to auto-cleanup associated ffmpeg objects. */
struct AVIOContextDeleter {
    void operator()(AVIOContext *ptr) { avio_closep(&ptr); }
};
using AVIOContextPtr = std::unique_ptr<AVIOContext,AVIOContextDeleter>;

struct AVFormatCtxDeleter {
    void operator()(AVFormatContext *ptr) { avformat_close_input(&ptr); }
};
using AVFormatCtxPtr = std::unique_ptr<AVFormatContext,AVFormatCtxDeleter>;

struct AVCodecCtxDeleter {
    void operator()(AVCodecContext *ptr) { avcodec_free_context(&ptr); }
};
using AVCodecCtxPtr = std::unique_ptr<AVCodecContext,AVCodecCtxDeleter>;

struct AVFrameDeleter {
    void operator()(AVFrame *ptr) { av_frame_free(&ptr); }
};
using AVFramePtr = std::unique_ptr<AVFrame,AVFrameDeleter>;

struct SwrContextDeleter {
    void operator()(SwrContext *ptr) { swr_free(&ptr); }
};
using SwrContextPtr = std::unique_ptr<SwrContext,SwrContextDeleter>;

struct SwsContextDeleter {
    void operator()(SwsContext *ptr) { sws_freeContext(ptr); }
};
using SwsContextPtr = std::unique_ptr<SwsContext,SwsContextDeleter>;


template<size_t SizeLimit>
class PacketQueue {
    std::mutex mMutex;
    std::condition_variable mCondVar;
    std::deque<AVPacket> mPackets;
    size_t mTotalSize{0};
    bool mFinished{false};

    AVPacket *getPacket(std::unique_lock<std::mutex> &lock)
    {
        while(mPackets.empty() && !mFinished)
            mCondVar.wait(lock);
        return mPackets.empty() ? nullptr : &mPackets.front();
    }

    void pop()
    {
        AVPacket *pkt = &mPackets.front();
        mTotalSize -= static_cast<unsigned int>(pkt->size);
        av_packet_unref(pkt);
        mPackets.pop_front();
    }

public:
    ~PacketQueue()
    {
        for(AVPacket &pkt : mPackets)
            av_packet_unref(&pkt);
        mPackets.clear();
        mTotalSize = 0;
    }

    int sendTo(AVCodecContext *codecctx)
    {
        std::unique_lock<std::mutex> lock{mMutex};

        AVPacket *pkt{getPacket(lock)};
        if(!pkt) return avcodec_send_packet(codecctx, nullptr);

        const int ret{avcodec_send_packet(codecctx, pkt)};
        if(ret != AVERROR(EAGAIN))
        {
            if(ret < 0)
                std::cerr<< "Failed to send packet: "<<ret <<std::endl;
            pop();
        }
        return ret;
    }

    void setFinished()
    {
        {
            std::lock_guard<std::mutex> _{mMutex};
            mFinished = true;
        }
        mCondVar.notify_one();
    }

    bool put(const AVPacket *pkt)
    {
        {
            std::unique_lock<std::mutex> lock{mMutex};
            if(mTotalSize >= SizeLimit)
                return false;

            mPackets.push_back(AVPacket{});
            if(av_packet_ref(&mPackets.back(), pkt) != 0)
            {
                mPackets.pop_back();
                return true;
            }

            mTotalSize += static_cast<unsigned int>(mPackets.back().size);
        }
        mCondVar.notify_one();
        return true;
    }
};


struct MovieState;

struct AudioState {
    MovieState &mMovie;

    AVStream *mStream{nullptr};
    AVCodecCtxPtr mCodecCtx;

    PacketQueue<2*1024*1024> mPackets;

    /* Used for clock difference average computation */
    seconds_d64 mClockDiffAvg{0};

    /* Time of the next sample to be buffered */
    nanoseconds mCurrentPts{0};

    /* Device clock time that the stream started at. */
    nanoseconds mDeviceStartTime{nanoseconds::min()};

    /* Decompressed sample frame, and swresample context for conversion */
    AVFramePtr    mDecodedFrame;
    SwrContextPtr mSwresCtx;

    /* Conversion format, for what gets fed to OpenAL */
    uint64_t       mDstChanLayout{0};
    AVSampleFormat mDstSampleFmt{AV_SAMPLE_FMT_NONE};

    /* Storage of converted samples */
    uint8_t *mSamples{nullptr};
    int mSamplesLen{0}; /* In samples */
    int mSamplesPos{0};
    int mSamplesMax{0};

    std::unique_ptr<uint8_t[]> mBufferData;
    size_t mBufferDataSize{0};
    std::atomic<size_t> mReadPos{0};
    std::atomic<size_t> mWritePos{0};

    /* OpenAL format */
    ALenum mFormat{AL_NONE};
    ALuint mFrameSize{0};

    std::mutex mSrcMutex;
    std::condition_variable mSrcCond;
    std::atomic_flag mConnected;
    ALuint mSource{0};
    std::array<ALuint,AudioBufferCount> mBuffers{};
    ALuint mBufferIdx{0};

    AudioState(MovieState &movie) : mMovie(movie)
    { mConnected.test_and_set(std::memory_order_relaxed); }
    ~AudioState()
    {
        if(mSource)
            alDeleteSources(1, &mSource);
        if(mBuffers[0])
            alDeleteBuffers(static_cast<ALsizei>(mBuffers.size()), mBuffers.data());

        av_freep(&mSamples);
    }

#ifdef AL_SOFT_events
    static void AL_APIENTRY EventCallback(ALenum eventType, ALuint object, ALuint param,
        ALsizei length, const ALchar *message, void *userParam);
#endif
#ifdef AL_SOFT_callback_buffer
    static ALsizei AL_APIENTRY bufferCallbackC(void *userptr, void *data, ALsizei size)
    { return static_cast<AudioState*>(userptr)->bufferCallback(data, size); }
    ALsizei bufferCallback(void *data, ALsizei size);
#endif

    nanoseconds getClockNoLock();
    nanoseconds getClock()
    {
        std::lock_guard<std::mutex> lock{mSrcMutex};
        return getClockNoLock();
    }

    bool startPlayback();

    int getSync();
    int decodeFrame();
    bool readAudio(uint8_t *samples, unsigned int length, int &sample_skip);
    void readAudio(int sample_skip);

    int handler();
};

struct VideoState {
    MovieState &mMovie;

    AVStream *mStream{nullptr};
    AVCodecCtxPtr mCodecCtx;

    PacketQueue<14*1024*1024> mPackets;

    /* The pts of the currently displayed frame, and the time (av_gettime) it
     * was last updated - used to have running video pts
     */
    nanoseconds mDisplayPts{0};
    microseconds mDisplayPtsTime{microseconds::min()};
    std::mutex mDispPtsMutex;

    /* Swscale context for format conversion */
    SwsContextPtr mSwscaleCtx;

    struct Picture {
        AVFramePtr mFrame{};
        nanoseconds mPts{nanoseconds::min()};
    };
    std::array<Picture,VIDEO_PICTURE_QUEUE_SIZE> mPictQ;
    std::atomic<size_t> mPictQRead{0u}, mPictQWrite{1u};
    std::mutex mPictQMutex;
    std::condition_variable mPictQCond;

    SDL_Texture *mImage{nullptr};
    int mWidth{0}, mHeight{0}; /* Logical image size (actual size may be larger) */
    bool mFirstUpdate{true};

    std::atomic<bool> mEOS{false};
    std::atomic<bool> mFinalUpdate{false};

    VideoState(MovieState &movie) : mMovie(movie) { }
    ~VideoState()
    {
        if(mImage)
            SDL_DestroyTexture(mImage);
        mImage = nullptr;
    }

    nanoseconds getClock();

    void display(SDL_Window *screen, SDL_Renderer *renderer);
    void updateVideo(SDL_Window *screen, SDL_Renderer *renderer, bool redraw);
    int handler();
};

struct MovieState {
    AVIOContextPtr mIOContext;
    AVFormatCtxPtr mFormatCtx;

    SyncMaster mAVSyncType{SyncMaster::Default};

    microseconds mClockBase{microseconds::min()};

    std::atomic<bool> mQuit{false};

    AudioState mAudio;
    VideoState mVideo;

    std::thread mParseThread;
    std::thread mAudioThread;
    std::thread mVideoThread;

    std::string mFilename;

    MovieState(std::string fname)
      : mAudio(*this), mVideo(*this), mFilename(std::move(fname))
    { }
    ~MovieState()
    {
        mQuit = true;
        if(mParseThread.joinable())
            mParseThread.join();
    }

    static int decode_interrupt_cb(void *ctx);
    bool prepare();
    void setTitle(SDL_Window *window);

    nanoseconds getClock();

    nanoseconds getMasterClock();

    nanoseconds getDuration();

    int streamComponentOpen(unsigned int stream_index);
    int parse_handler();
};


nanoseconds AudioState::getClockNoLock()
{
    // The audio clock is the timestamp of the sample currently being heard.
    if(alcGetInteger64vSOFT)
    {
        // If device start time = min, we aren't playing yet.
        if(mDeviceStartTime == nanoseconds::min())
            return nanoseconds::zero();

        // Get the current device clock time and latency.
        auto device = alcGetContextsDevice(alcGetCurrentContext());
        ALCint64SOFT devtimes[2]{0,0};
        alcGetInteger64vSOFT(device, ALC_DEVICE_CLOCK_LATENCY_SOFT, 2, devtimes);
        auto latency = nanoseconds{devtimes[1]};
        auto device_time = nanoseconds{devtimes[0]};

        // The clock is simply the current device time relative to the recorded
        // start time. We can also subtract the latency to get more a accurate
        // position of where the audio device actually is in the output stream.
        return device_time - mDeviceStartTime - latency;
    }

    if(mBufferDataSize > 0)
    {
        if(mDeviceStartTime == nanoseconds::min())
            return nanoseconds::zero();

        /* With a callback buffer and no device clock, mDeviceStartTime is
         * actually the timestamp of the first sample frame played. The audio
         * clock, then, is that plus the current source offset.
         */
        ALint64SOFT offset[2];
        if(alGetSourcei64vSOFT)
            alGetSourcei64vSOFT(mSource, AL_SAMPLE_OFFSET_LATENCY_SOFT, offset);
        else
        {
            ALint ioffset;
            alGetSourcei(mSource, AL_SAMPLE_OFFSET, &ioffset);
            offset[0] = ALint64SOFT{ioffset} << 32;
            offset[1] = 0;
        }
        /* NOTE: The source state must be checked last, in case an underrun
         * occurs and the source stops between getting the state and retrieving
         * the offset+latency.
         */
        ALint status;
        alGetSourcei(mSource, AL_SOURCE_STATE, &status);

        nanoseconds pts{};
        if(status == AL_PLAYING || status == AL_PAUSED)
            pts = mDeviceStartTime - nanoseconds{offset[1]} +
                duration_cast<nanoseconds>(fixed32{offset[0] / mCodecCtx->sample_rate});
        else
        {
            /* If the source is stopped, the pts of the next sample to be heard
             * is the pts of the next sample to be buffered, minus the amount
             * already in the buffer ready to play.
             */
            const size_t woffset{mWritePos.load(std::memory_order_acquire)};
            const size_t roffset{mReadPos.load(std::memory_order_relaxed)};
            const size_t readable{((woffset >= roffset) ? woffset : (mBufferDataSize+woffset)) -
                roffset};

            pts = mCurrentPts - nanoseconds{seconds{readable/mFrameSize}}/mCodecCtx->sample_rate;
        }

        return pts;
    }

    /* The source-based clock is based on 4 components:
     * 1 - The timestamp of the next sample to buffer (mCurrentPts)
     * 2 - The length of the source's buffer queue
     *     (AudioBufferTime*AL_BUFFERS_QUEUED)
     * 3 - The offset OpenAL is currently at in the source (the first value
     *     from AL_SAMPLE_OFFSET_LATENCY_SOFT)
     * 4 - The latency between OpenAL and the DAC (the second value from
     *     AL_SAMPLE_OFFSET_LATENCY_SOFT)
     *
     * Subtracting the length of the source queue from the next sample's
     * timestamp gives the timestamp of the sample at the start of the source
     * queue. Adding the source offset to that results in the timestamp for the
     * sample at OpenAL's current position, and subtracting the source latency
     * from that gives the timestamp of the sample currently at the DAC.
     */
    nanoseconds pts{mCurrentPts};
    if(mSource)
    {
        ALint64SOFT offset[2];
        if(alGetSourcei64vSOFT)
            alGetSourcei64vSOFT(mSource, AL_SAMPLE_OFFSET_LATENCY_SOFT, offset);
        else
        {
            ALint ioffset;
            alGetSourcei(mSource, AL_SAMPLE_OFFSET, &ioffset);
            offset[0] = ALint64SOFT{ioffset} << 32;
            offset[1] = 0;
        }
        ALint queued, status;
        alGetSourcei(mSource, AL_BUFFERS_QUEUED, &queued);
        alGetSourcei(mSource, AL_SOURCE_STATE, &status);

        /* If the source is AL_STOPPED, then there was an underrun and all
         * buffers are processed, so ignore the source queue. The audio thread
         * will put the source into an AL_INITIAL state and clear the queue
         * when it starts recovery.
         */
        if(status != AL_STOPPED)
        {
            pts -= AudioBufferTime*queued;
            pts += duration_cast<nanoseconds>(fixed32{offset[0] / mCodecCtx->sample_rate});
        }
        /* Don't offset by the latency if the source isn't playing. */
        if(status == AL_PLAYING)
            pts -= nanoseconds{offset[1]};
    }

    return std::max(pts, nanoseconds::zero());
}

bool AudioState::startPlayback()
{
    const size_t woffset{mWritePos.load(std::memory_order_acquire)};
    const size_t roffset{mReadPos.load(std::memory_order_relaxed)};
    const size_t readable{((woffset >= roffset) ? woffset : (mBufferDataSize+woffset)) -
        roffset};

    if(mBufferDataSize > 0)
    {
        if(readable == 0)
            return false;
        if(!alcGetInteger64vSOFT)
            mDeviceStartTime = mCurrentPts -
                nanoseconds{seconds{readable/mFrameSize}}/mCodecCtx->sample_rate;
    }
    else
    {
        ALint queued{};
        alGetSourcei(mSource, AL_BUFFERS_QUEUED, &queued);
        if(queued == 0) return false;
    }

    alSourcePlay(mSource);
    if(alcGetInteger64vSOFT)
    {
        /* Subtract the total buffer queue time from the current pts to get the
         * pts of the start of the queue.
         */
        int64_t srctimes[2]{0,0};
        alGetSourcei64vSOFT(mSource, AL_SAMPLE_OFFSET_CLOCK_SOFT, srctimes);
        auto device_time = nanoseconds{srctimes[1]};
        auto src_offset = duration_cast<nanoseconds>(fixed32{srctimes[0]}) /
            mCodecCtx->sample_rate;

        /* The mixer may have ticked and incremented the device time and sample
         * offset, so subtract the source offset from the device time to get
         * the device time the source started at. Also subtract startpts to get
         * the device time the stream would have started at to reach where it
         * is now.
         */
        if(mBufferDataSize > 0)
        {
            nanoseconds startpts{mCurrentPts -
                nanoseconds{seconds{readable/mFrameSize}}/mCodecCtx->sample_rate};
            mDeviceStartTime = device_time - src_offset - startpts;
        }
        else
        {
            nanoseconds startpts{mCurrentPts - AudioBufferTotalTime};
            mDeviceStartTime = device_time - src_offset - startpts;
        }
    }
    return true;
}

int AudioState::getSync()
{
    if(mMovie.mAVSyncType == SyncMaster::Audio)
        return 0;

    auto ref_clock = mMovie.getMasterClock();
    auto diff = ref_clock - getClockNoLock();

    if(!(diff < AVNoSyncThreshold && diff > -AVNoSyncThreshold))
    {
        /* Difference is TOO big; reset accumulated average */
        mClockDiffAvg = seconds_d64::zero();
        return 0;
    }

    /* Accumulate the diffs */
    mClockDiffAvg = mClockDiffAvg*AudioAvgFilterCoeff + diff;
    auto avg_diff = mClockDiffAvg*(1.0 - AudioAvgFilterCoeff);
    if(avg_diff < AudioSyncThreshold/2.0 && avg_diff > -AudioSyncThreshold)
        return 0;

    /* Constrain the per-update difference to avoid exceedingly large skips */
    diff = std::min<nanoseconds>(diff, AudioSampleCorrectionMax);
    return static_cast<int>(duration_cast<seconds>(diff*mCodecCtx->sample_rate).count());
}

int AudioState::decodeFrame()
{
    while(!mMovie.mQuit.load(std::memory_order_relaxed))
    {
        int ret;
        while((ret=avcodec_receive_frame(mCodecCtx.get(), mDecodedFrame.get())) == AVERROR(EAGAIN))
            mPackets.sendTo(mCodecCtx.get());
        if(ret != 0)
        {
            if(ret == AVErrorEOF) break;
            std::cerr<< "Failed to receive frame: "<<ret <<std::endl;
            continue;
        }

        if(mDecodedFrame->nb_samples <= 0)
            continue;

        /* If provided, update w/ pts */
        if(mDecodedFrame->best_effort_timestamp != AVNoPtsValue)
            mCurrentPts = duration_cast<nanoseconds>(seconds_d64{av_q2d(mStream->time_base) *
                static_cast<double>(mDecodedFrame->best_effort_timestamp)});

        if(mDecodedFrame->nb_samples > mSamplesMax)
        {
            av_freep(&mSamples);
            av_samples_alloc(&mSamples, nullptr, mCodecCtx->channels, mDecodedFrame->nb_samples,
                mDstSampleFmt, 0);
            mSamplesMax = mDecodedFrame->nb_samples;
        }
        /* Return the amount of sample frames converted */
        int data_size{swr_convert(mSwresCtx.get(), &mSamples, mDecodedFrame->nb_samples,
            const_cast<const uint8_t**>(mDecodedFrame->data), mDecodedFrame->nb_samples)};

        av_frame_unref(mDecodedFrame.get());
        return data_size;
    }

    return 0;
}

/* Duplicates the sample at in to out, count times. The frame size is a
 * multiple of the template type size.
 */
template<typename T>
static void sample_dup(uint8_t *out, const uint8_t *in, size_t count, size_t frame_size)
{
    auto *sample = reinterpret_cast<const T*>(in);
    auto *dst = reinterpret_cast<T*>(out);
    if(frame_size == sizeof(T))
        std::fill_n(dst, count, *sample);
    else
    {
        /* NOTE: frame_size is a multiple of sizeof(T). */
        size_t type_mult{frame_size / sizeof(T)};
        size_t i{0};
        std::generate_n(dst, count*type_mult,
            [sample,type_mult,&i]() -> T
            {
                T ret = sample[i];
                i = (i+1)%type_mult;
                return ret;
            }
        );
    }
}


bool AudioState::readAudio(uint8_t *samples, unsigned int length, int &sample_skip)
{
    unsigned int audio_size{0};

    /* Read the next chunk of data, refill the buffer, and queue it
     * on the source */
    length /= mFrameSize;
    while(mSamplesLen > 0 && audio_size < length)
    {
        unsigned int rem{length - audio_size};
        if(mSamplesPos >= 0)
        {
            const auto len = static_cast<unsigned int>(mSamplesLen - mSamplesPos);
            if(rem > len) rem = len;
            std::copy_n(mSamples + static_cast<unsigned int>(mSamplesPos)*mFrameSize,
                rem*mFrameSize, samples);
        }
        else
        {
            rem = std::min(rem, static_cast<unsigned int>(-mSamplesPos));

            /* Add samples by copying the first sample */
            if((mFrameSize&7) == 0)
                sample_dup<uint64_t>(samples, mSamples, rem, mFrameSize);
            else if((mFrameSize&3) == 0)
                sample_dup<uint32_t>(samples, mSamples, rem, mFrameSize);
            else if((mFrameSize&1) == 0)
                sample_dup<uint16_t>(samples, mSamples, rem, mFrameSize);
            else
                sample_dup<uint8_t>(samples, mSamples, rem, mFrameSize);
        }

        mSamplesPos += rem;
        mCurrentPts += nanoseconds{seconds{rem}} / mCodecCtx->sample_rate;
        samples += rem*mFrameSize;
        audio_size += rem;

        while(mSamplesPos >= mSamplesLen)
        {
            int frame_len = decodeFrame();
            if(frame_len <= 0) break;

            mSamplesLen = frame_len;
            mSamplesPos = std::min(mSamplesLen, sample_skip);
            sample_skip -= mSamplesPos;

            // Adjust the device start time and current pts by the amount we're
            // skipping/duplicating, so that the clock remains correct for the
            // current stream position.
            auto skip = nanoseconds{seconds{mSamplesPos}} / mCodecCtx->sample_rate;
            mDeviceStartTime -= skip;
            mCurrentPts += skip;
            continue;
        }
    }
    if(audio_size <= 0)
        return false;

    if(audio_size < length)
    {
        const unsigned int rem{length - audio_size};
        std::fill_n(samples, rem*mFrameSize,
            (mDstSampleFmt == AV_SAMPLE_FMT_U8) ? 0x80 : 0x00);
        mCurrentPts += nanoseconds{seconds{rem}} / mCodecCtx->sample_rate;
        audio_size += rem;
    }
    return true;
}

void AudioState::readAudio(int sample_skip)
{
    size_t woffset{mWritePos.load(std::memory_order_acquire)};
    while(mSamplesLen > 0)
    {
        const size_t roffset{mReadPos.load(std::memory_order_relaxed)};

        if(mSamplesPos < 0)
        {
            size_t rem{(((roffset > woffset) ? roffset-1
                : ((roffset == 0) ? mBufferDataSize-1
                : mBufferDataSize)) - woffset) / mFrameSize};
            rem = std::min<size_t>(rem, static_cast<ALuint>(-mSamplesPos));
            if(rem == 0) break;

            auto *splout{&mBufferData[woffset]};
            if((mFrameSize&7) == 0)
                sample_dup<uint64_t>(splout, mSamples, rem, mFrameSize);
            else if((mFrameSize&3) == 0)
                sample_dup<uint32_t>(splout, mSamples, rem, mFrameSize);
            else if((mFrameSize&1) == 0)
                sample_dup<uint16_t>(splout, mSamples, rem, mFrameSize);
            else
                sample_dup<uint8_t>(splout, mSamples, rem, mFrameSize);
            woffset += rem * mFrameSize;
            if(woffset == mBufferDataSize)
                woffset = 0;
            mWritePos.store(woffset, std::memory_order_release);
            mSamplesPos += static_cast<int>(rem);
            mCurrentPts += nanoseconds{seconds{rem}} / mCodecCtx->sample_rate;
            continue;
        }

        const size_t boffset{static_cast<ALuint>(mSamplesPos) * size_t{mFrameSize}};
        const size_t nbytes{static_cast<ALuint>(mSamplesLen)*size_t{mFrameSize} -
            boffset};
        if(roffset > woffset)
        {
            const size_t writable{roffset-woffset-1};
            if(writable < nbytes) break;

            memcpy(&mBufferData[woffset], mSamples+boffset, nbytes);
            woffset += nbytes;
        }
        else
        {
            const size_t writable{mBufferDataSize+roffset-woffset-1};
            if(writable < nbytes) break;

            const size_t todo1{std::min<size_t>(nbytes, mBufferDataSize-woffset)};
            const size_t todo2{nbytes - todo1};

            memcpy(&mBufferData[woffset], mSamples+boffset, todo1);
            woffset += todo1;
            if(woffset == mBufferDataSize)
            {
                woffset = 0;
                if(todo2 > 0)
                {
                    memcpy(&mBufferData[woffset], mSamples+boffset+todo1, todo2);
                    woffset += todo2;
                }
            }
        }
        mWritePos.store(woffset, std::memory_order_release);
        mCurrentPts += nanoseconds{seconds{mSamplesLen-mSamplesPos}} / mCodecCtx->sample_rate;

        do {
            mSamplesLen = decodeFrame();
            if(mSamplesLen <= 0) break;

            mSamplesPos = std::min(mSamplesLen, sample_skip);
            sample_skip -= mSamplesPos;

            auto skip = nanoseconds{seconds{mSamplesPos}} / mCodecCtx->sample_rate;
            mDeviceStartTime -= skip;
            mCurrentPts += skip;
        } while(mSamplesPos >= mSamplesLen);
    }
}


#ifdef AL_SOFT_events
void AL_APIENTRY AudioState::EventCallback(ALenum eventType, ALuint object, ALuint param,
    ALsizei length, const ALchar *message, void *userParam)
{
    auto self = static_cast<AudioState*>(userParam);

    if(eventType == AL_EVENT_TYPE_BUFFER_COMPLETED_SOFT)
    {
        /* Temporarily lock the source mutex to ensure it's not between
         * checking the processed count and going to sleep.
         */
        std::unique_lock<std::mutex>{self->mSrcMutex}.unlock();
        self->mSrcCond.notify_one();
        return;
    }

    std::cout<< "\n---- AL Event on AudioState "<<self<<" ----\nEvent: ";
    switch(eventType)
    {
    case AL_EVENT_TYPE_BUFFER_COMPLETED_SOFT: std::cout<< "Buffer completed"; break;
    case AL_EVENT_TYPE_SOURCE_STATE_CHANGED_SOFT: std::cout<< "Source state changed"; break;
    case AL_EVENT_TYPE_DISCONNECTED_SOFT: std::cout<< "Disconnected"; break;
    default:
        std::cout<< "0x"<<std::hex<<std::setw(4)<<std::setfill('0')<<eventType<<std::dec<<
            std::setw(0)<<std::setfill(' '); break;
    }
    std::cout<< "\n"
        "Object ID: "<<object<<"\n"
        "Parameter: "<<param<<"\n"
        "Message: "<<std::string{message, static_cast<ALuint>(length)}<<"\n----"<<
        std::endl;

    if(eventType == AL_EVENT_TYPE_DISCONNECTED_SOFT)
    {
        {
            std::lock_guard<std::mutex> lock{self->mSrcMutex};
            self->mConnected.clear(std::memory_order_release);
        }
        self->mSrcCond.notify_one();
    }
}
#endif

#ifdef AL_SOFT_callback_buffer
ALsizei AudioState::bufferCallback(void *data, ALsizei size)
{
    ALsizei got{0};

    size_t roffset{mReadPos.load(std::memory_order_acquire)};
    while(got < size)
    {
        const size_t woffset{mWritePos.load(std::memory_order_relaxed)};
        if(woffset == roffset) break;

        size_t todo{((woffset < roffset) ? mBufferDataSize : woffset) - roffset};
        todo = std::min<size_t>(todo, static_cast<ALuint>(size-got));

        memcpy(data, &mBufferData[roffset], todo);
        data = static_cast<ALbyte*>(data) + todo;
        got += static_cast<ALsizei>(todo);

        roffset += todo;
        if(roffset == mBufferDataSize)
            roffset = 0;
    }
    mReadPos.store(roffset, std::memory_order_release);

    return got;
}
#endif

int AudioState::handler()
{
    std::unique_lock<std::mutex> srclock{mSrcMutex, std::defer_lock};
    milliseconds sleep_time{AudioBufferTime / 3};
    ALenum fmt;

#ifdef AL_SOFT_events
    const std::array<ALenum,3> evt_types{{
        AL_EVENT_TYPE_BUFFER_COMPLETED_SOFT, AL_EVENT_TYPE_SOURCE_STATE_CHANGED_SOFT,
        AL_EVENT_TYPE_DISCONNECTED_SOFT}};
    if(alEventControlSOFT)
    {
        alEventControlSOFT(evt_types.size(), evt_types.data(), AL_TRUE);
        alEventCallbackSOFT(EventCallback, this);
        sleep_time = AudioBufferTotalTime;
    }
#endif
#ifdef AL_SOFT_bformat_ex
    const bool has_bfmt_ex{alIsExtensionPresent("AL_SOFT_bformat_ex") != AL_FALSE};
    ALenum ambi_layout{AL_FUMA_SOFT};
    ALenum ambi_scale{AL_FUMA_SOFT};
#endif

    /* Find a suitable format for OpenAL. */
    mDstChanLayout = 0;
    mFormat = AL_NONE;
    if((mCodecCtx->sample_fmt == AV_SAMPLE_FMT_FLT || mCodecCtx->sample_fmt == AV_SAMPLE_FMT_FLTP) &&
       alIsExtensionPresent("AL_EXT_FLOAT32"))
    {
        mDstSampleFmt = AV_SAMPLE_FMT_FLT;
        mFrameSize = 4;
        if(mCodecCtx->channel_layout == AV_CH_LAYOUT_7POINT1 &&
           alIsExtensionPresent("AL_EXT_MCFORMATS") &&
           (fmt=alGetEnumValue("AL_FORMAT_71CHN32")) != AL_NONE && fmt != -1)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 8;
            mFormat = fmt;
        }
        if((mCodecCtx->channel_layout == AV_CH_LAYOUT_5POINT1 ||
            mCodecCtx->channel_layout == AV_CH_LAYOUT_5POINT1_BACK) &&
           alIsExtensionPresent("AL_EXT_MCFORMATS") &&
           (fmt=alGetEnumValue("AL_FORMAT_51CHN32")) != AL_NONE && fmt != -1)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 6;
            mFormat = fmt;
        }
        if(mCodecCtx->channel_layout == AV_CH_LAYOUT_MONO)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 1;
            mFormat = AL_FORMAT_MONO_FLOAT32;
        }
        /* Assume 3D B-Format (ambisonics) if the channel layout is blank and
         * there's 4 or more channels. FFmpeg/libavcodec otherwise seems to
         * have no way to specify if the source is actually B-Format (let alone
         * if it's 2D or 3D).
         */
        if(mCodecCtx->channel_layout == 0 && mCodecCtx->channels >= 4 &&
           alIsExtensionPresent("AL_EXT_BFORMAT") &&
           (fmt=alGetEnumValue("AL_FORMAT_BFORMAT3D_FLOAT32")) != AL_NONE && fmt != -1)
        {
            int order{static_cast<int>(std::sqrt(mCodecCtx->channels)) - 1};
            if((order+1)*(order+1) == mCodecCtx->channels ||
               (order+1)*(order+1) + 2 == mCodecCtx->channels)
            {
                /* OpenAL only supports first-order with AL_EXT_BFORMAT, which
                 * is 4 channels for 3D buffers.
                 */
                mFrameSize *= 4;
                mFormat = fmt;
            }
        }
        if(!mFormat)
        {
            mDstChanLayout = AV_CH_LAYOUT_STEREO;
            mFrameSize *= 2;
            mFormat = AL_FORMAT_STEREO_FLOAT32;
        }
    }
    if(mCodecCtx->sample_fmt == AV_SAMPLE_FMT_U8 || mCodecCtx->sample_fmt == AV_SAMPLE_FMT_U8P)
    {
        mDstSampleFmt = AV_SAMPLE_FMT_U8;
        mFrameSize = 1;
        if(mCodecCtx->channel_layout == AV_CH_LAYOUT_7POINT1 &&
           alIsExtensionPresent("AL_EXT_MCFORMATS") &&
           (fmt=alGetEnumValue("AL_FORMAT_71CHN8")) != AL_NONE && fmt != -1)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 8;
            mFormat = fmt;
        }
        if((mCodecCtx->channel_layout == AV_CH_LAYOUT_5POINT1 ||
            mCodecCtx->channel_layout == AV_CH_LAYOUT_5POINT1_BACK) &&
           alIsExtensionPresent("AL_EXT_MCFORMATS") &&
           (fmt=alGetEnumValue("AL_FORMAT_51CHN8")) != AL_NONE && fmt != -1)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 6;
            mFormat = fmt;
        }
        if(mCodecCtx->channel_layout == AV_CH_LAYOUT_MONO)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 1;
            mFormat = AL_FORMAT_MONO8;
        }
        if(mCodecCtx->channel_layout == 0 && mCodecCtx->channels >= 4 &&
           alIsExtensionPresent("AL_EXT_BFORMAT") &&
           (fmt=alGetEnumValue("AL_FORMAT_BFORMAT3D8")) != AL_NONE && fmt != -1)
        {
            int order{static_cast<int>(std::sqrt(mCodecCtx->channels)) - 1};
            if((order+1)*(order+1) == mCodecCtx->channels ||
               (order+1)*(order+1) + 2 == mCodecCtx->channels)
            {
                mFrameSize *= 4;
                mFormat = fmt;
            }
        }
        if(!mFormat)
        {
            mDstChanLayout = AV_CH_LAYOUT_STEREO;
            mFrameSize *= 2;
            mFormat = AL_FORMAT_STEREO8;
        }
    }
    if(!mFormat)
    {
        mDstSampleFmt = AV_SAMPLE_FMT_S16;
        mFrameSize = 2;
        if(mCodecCtx->channel_layout == AV_CH_LAYOUT_7POINT1 &&
           alIsExtensionPresent("AL_EXT_MCFORMATS") &&
           (fmt=alGetEnumValue("AL_FORMAT_71CHN16")) != AL_NONE && fmt != -1)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 8;
            mFormat = fmt;
        }
        if((mCodecCtx->channel_layout == AV_CH_LAYOUT_5POINT1 ||
            mCodecCtx->channel_layout == AV_CH_LAYOUT_5POINT1_BACK) &&
           alIsExtensionPresent("AL_EXT_MCFORMATS") &&
           (fmt=alGetEnumValue("AL_FORMAT_51CHN16")) != AL_NONE && fmt != -1)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 6;
            mFormat = fmt;
        }
        if(mCodecCtx->channel_layout == AV_CH_LAYOUT_MONO)
        {
            mDstChanLayout = mCodecCtx->channel_layout;
            mFrameSize *= 1;
            mFormat = AL_FORMAT_MONO16;
        }
        if(mCodecCtx->channel_layout == 0 && mCodecCtx->channels >= 4 &&
           alIsExtensionPresent("AL_EXT_BFORMAT") &&
           (fmt=alGetEnumValue("AL_FORMAT_BFORMAT3D16")) != AL_NONE && fmt != -1)
        {
            int order{static_cast<int>(std::sqrt(mCodecCtx->channels)) - 1};
            if((order+1)*(order+1) == mCodecCtx->channels ||
               (order+1)*(order+1) + 2 == mCodecCtx->channels)
            {
                mFrameSize *= 4;
                mFormat = fmt;
            }
        }
        if(!mFormat)
        {
            mDstChanLayout = AV_CH_LAYOUT_STEREO;
            mFrameSize *= 2;
            mFormat = AL_FORMAT_STEREO16;
        }
    }
    void *samples{nullptr};
    ALsizei buffer_len{0};

    mSamples = nullptr;
    mSamplesMax = 0;
    mSamplesPos = 0;
    mSamplesLen = 0;

    mDecodedFrame.reset(av_frame_alloc());
    if(!mDecodedFrame)
    {
        std::cerr<< "Failed to allocate audio frame" <<std::endl;
        goto finish;
    }

    if(!mDstChanLayout)
    {
        /* OpenAL only supports first-order ambisonics with AL_EXT_BFORMAT, so
         * we have to drop any extra channels.
         */
        mSwresCtx.reset(swr_alloc_set_opts(nullptr,
            (1_i64<<4)-1, mDstSampleFmt, mCodecCtx->sample_rate,
            (1_i64<<mCodecCtx->channels)-1, mCodecCtx->sample_fmt, mCodecCtx->sample_rate,
            0, nullptr));

        /* Note that ffmpeg/libavcodec has no method to check the ambisonic
         * channel order and normalization, so we can only assume AmbiX as the
         * defacto-standard. This is not true for .amb files, which use FuMa.
         */
        std::vector<double> mtx(64*64, 0.0);
#ifdef AL_SOFT_bformat_ex
        ambi_layout = AL_ACN_SOFT;
        ambi_scale = AL_SN3D_SOFT;
        if(has_bfmt_ex)
        {
            /* An identity matrix that doesn't remix any channels. */
            std::cout<< "Found AL_SOFT_bformat_ex" <<std::endl;
            mtx[0 + 0*64] = 1.0;
            mtx[1 + 1*64] = 1.0;
            mtx[2 + 2*64] = 1.0;
            mtx[3 + 3*64] = 1.0;
        }
        else
#endif
        {
            std::cout<< "Found AL_EXT_BFORMAT" <<std::endl;
            /* Without AL_SOFT_bformat_ex, OpenAL only supports FuMa channel
             * ordering and normalization, so a custom matrix is needed to
             * scale and reorder the source from AmbiX.
             */
            mtx[0 + 0*64] = std::sqrt(0.5);
            mtx[3 + 1*64] = 1.0;
            mtx[1 + 2*64] = 1.0;
            mtx[2 + 3*64] = 1.0;
        }
        swr_set_matrix(mSwresCtx.get(), mtx.data(), 64);
    }
    else
        mSwresCtx.reset(swr_alloc_set_opts(nullptr,
            static_cast<int64_t>(mDstChanLayout), mDstSampleFmt, mCodecCtx->sample_rate,
            mCodecCtx->channel_layout ? static_cast<int64_t>(mCodecCtx->channel_layout)
                : av_get_default_channel_layout(mCodecCtx->channels),
            mCodecCtx->sample_fmt, mCodecCtx->sample_rate,
            0, nullptr));
    if(!mSwresCtx || swr_init(mSwresCtx.get()) != 0)
    {
        std::cerr<< "Failed to initialize audio converter" <<std::endl;
        goto finish;
    }

    alGenBuffers(static_cast<ALsizei>(mBuffers.size()), mBuffers.data());
    alGenSources(1, &mSource);

    if(DirectOutMode)
        alSourcei(mSource, AL_DIRECT_CHANNELS_SOFT, DirectOutMode);
    if(EnableWideStereo)
    {
        const float angles[2]{static_cast<float>(M_PI / 3.0), static_cast<float>(-M_PI / 3.0)};
        alSourcefv(mSource, AL_STEREO_ANGLES, angles);
    }
#ifdef AL_SOFT_bformat_ex
    if(has_bfmt_ex)
    {
        for(ALuint bufid : mBuffers)
        {
            alBufferi(bufid, AL_AMBISONIC_LAYOUT_SOFT, ambi_layout);
            alBufferi(bufid, AL_AMBISONIC_SCALING_SOFT, ambi_scale);
        }
    }
#endif

    if(alGetError() != AL_NO_ERROR)
        goto finish;

#ifdef AL_SOFT_callback_buffer
    if(alBufferCallbackSOFT)
    {
        alBufferCallbackSOFT(mBuffers[0], mFormat, mCodecCtx->sample_rate, bufferCallbackC, this,
            0);
        alSourcei(mSource, AL_BUFFER, static_cast<ALint>(mBuffers[0]));
        if(alGetError() != AL_NO_ERROR)
        {
            fprintf(stderr, "Failed to set buffer callback\n");
            alSourcei(mSource, AL_BUFFER, 0);
            buffer_len = static_cast<int>(duration_cast<seconds>(mCodecCtx->sample_rate *
                AudioBufferTime).count() * mFrameSize);
        }
        else
        {
            mBufferDataSize = static_cast<size_t>(duration_cast<seconds>(mCodecCtx->sample_rate *
                AudioBufferTotalTime).count()) * mFrameSize;
            mBufferData.reset(new uint8_t[mBufferDataSize]);
            mReadPos.store(0, std::memory_order_relaxed);
            mWritePos.store(0, std::memory_order_relaxed);

            ALCint refresh{};
            alcGetIntegerv(alcGetContextsDevice(alcGetCurrentContext()), ALC_REFRESH, 1, &refresh);
            sleep_time = milliseconds{seconds{1}} / refresh;
        }
    }
    else
#endif
        buffer_len = static_cast<int>(duration_cast<seconds>(mCodecCtx->sample_rate *
            AudioBufferTime).count() * mFrameSize);
    if(buffer_len > 0)
        samples = av_malloc(static_cast<ALuint>(buffer_len));

    /* Prefill the codec buffer. */
    do {
        const int ret{mPackets.sendTo(mCodecCtx.get())};
        if(ret == AVERROR(EAGAIN) || ret == AVErrorEOF)
            break;
    } while(1);

    srclock.lock();
    if(alcGetInteger64vSOFT)
    {
        int64_t devtime{};
        alcGetInteger64vSOFT(alcGetContextsDevice(alcGetCurrentContext()), ALC_DEVICE_CLOCK_SOFT,
            1, &devtime);
        mDeviceStartTime = nanoseconds{devtime} - mCurrentPts;
    }

    mSamplesLen = decodeFrame();
    if(mSamplesLen > 0)
    {
        mSamplesPos = std::min(mSamplesLen, getSync());

        auto skip = nanoseconds{seconds{mSamplesPos}} / mCodecCtx->sample_rate;
        mDeviceStartTime -= skip;
        mCurrentPts += skip;
    }

    while(!mMovie.mQuit.load(std::memory_order_relaxed)
        && mConnected.test_and_set(std::memory_order_relaxed))
    {
        ALenum state;
        if(mBufferDataSize > 0)
        {
            alGetSourcei(mSource, AL_SOURCE_STATE, &state);
            readAudio(getSync());
        }
        else
        {
            ALint processed, queued;

            /* First remove any processed buffers. */
            alGetSourcei(mSource, AL_BUFFERS_PROCESSED, &processed);
            while(processed > 0)
            {
                ALuint bid;
                alSourceUnqueueBuffers(mSource, 1, &bid);
                --processed;
            }

            /* Refill the buffer queue. */
            int sync_skip{getSync()};
            alGetSourcei(mSource, AL_BUFFERS_QUEUED, &queued);
            while(static_cast<ALuint>(queued) < mBuffers.size())
            {
                /* Read the next chunk of data, filling the buffer, and queue
                 * it on the source.
                 */
                const bool got_audio{readAudio(static_cast<uint8_t*>(samples),
                    static_cast<ALuint>(buffer_len), sync_skip)};
                if(!got_audio) break;

                const ALuint bufid{mBuffers[mBufferIdx]};
                mBufferIdx = static_cast<ALuint>((mBufferIdx+1) % mBuffers.size());

                alBufferData(bufid, mFormat, samples, buffer_len, mCodecCtx->sample_rate);
                alSourceQueueBuffers(mSource, 1, &bufid);
                ++queued;
            }

            /* Check that the source is playing. */
            alGetSourcei(mSource, AL_SOURCE_STATE, &state);
            if(state == AL_STOPPED)
            {
                /* AL_STOPPED means there was an underrun. Clear the buffer
                 * queue since this likely means we're late, and rewind the
                 * source to get it back into an AL_INITIAL state.
                 */
                alSourceRewind(mSource);
                alSourcei(mSource, AL_BUFFER, 0);
                if(alcGetInteger64vSOFT)
                {
                    /* Also update the device start time with the current
                     * device clock, so the decoder knows we're running behind.
                     */
                    int64_t devtime{};
                    alcGetInteger64vSOFT(alcGetContextsDevice(alcGetCurrentContext()),
                        ALC_DEVICE_CLOCK_SOFT, 1, &devtime);
                    mDeviceStartTime = nanoseconds{devtime} - mCurrentPts;
                }
                continue;
            }
        }

        /* (re)start the source if needed, and wait for a buffer to finish */
        if(state != AL_PLAYING && state != AL_PAUSED)
        {
            if(!startPlayback())
                break;
        }
        if(alGetError() != AL_NO_ERROR)
            return false;

        mSrcCond.wait_for(srclock, sleep_time);
    }

    alSourceRewind(mSource);
    alSourcei(mSource, AL_BUFFER, 0);
    srclock.unlock();

finish:
    av_freep(&samples);

#ifdef AL_SOFT_events
    if(alEventControlSOFT)
    {
        alEventControlSOFT(evt_types.size(), evt_types.data(), AL_FALSE);
        alEventCallbackSOFT(nullptr, nullptr);
    }
#endif

    return 0;
}


nanoseconds VideoState::getClock()
{
    /* NOTE: This returns incorrect times while not playing. */
    std::lock_guard<std::mutex> _{mDispPtsMutex};
    if(mDisplayPtsTime == microseconds::min())
        return nanoseconds::zero();
    auto delta = get_avtime() - mDisplayPtsTime;
    return mDisplayPts + delta;
}

/* Called by VideoState::updateVideo to display the next video frame. */
void VideoState::display(SDL_Window *screen, SDL_Renderer *renderer)
{
    if(!mImage)
        return;

    double aspect_ratio;
    int win_w, win_h;
    int w, h, x, y;

    if(mCodecCtx->sample_aspect_ratio.num == 0)
        aspect_ratio = 0.0;
    else
    {
        aspect_ratio = av_q2d(mCodecCtx->sample_aspect_ratio) * mCodecCtx->width /
                       mCodecCtx->height;
    }
    if(aspect_ratio <= 0.0)
        aspect_ratio = static_cast<double>(mCodecCtx->width) / mCodecCtx->height;

    SDL_GetWindowSize(screen, &win_w, &win_h);
    h = win_h;
    w = (static_cast<int>(std::rint(h * aspect_ratio)) + 3) & ~3;
    if(w > win_w)
    {
        w = win_w;
        h = (static_cast<int>(std::rint(w / aspect_ratio)) + 3) & ~3;
    }
    x = (win_w - w) / 2;
    y = (win_h - h) / 2;

    SDL_Rect src_rect{ 0, 0, mWidth, mHeight };
    SDL_Rect dst_rect{ x, y, w, h };
    SDL_RenderCopy(renderer, mImage, &src_rect, &dst_rect);
    SDL_RenderPresent(renderer);
}

/* Called regularly on the main thread where the SDL_Renderer was created. It
 * handles updating the textures of decoded frames and displaying the latest
 * frame.
 */
void VideoState::updateVideo(SDL_Window *screen, SDL_Renderer *renderer, bool redraw)
{
    size_t read_idx{mPictQRead.load(std::memory_order_relaxed)};
    Picture *vp{&mPictQ[read_idx]};

    auto clocktime = mMovie.getMasterClock();
    bool updated{false};
    while(1)
    {
        size_t next_idx{(read_idx+1)%mPictQ.size()};
        if(next_idx == mPictQWrite.load(std::memory_order_acquire))
            break;
        Picture *nextvp{&mPictQ[next_idx]};
        if(clocktime < nextvp->mPts)
            break;

        vp = nextvp;
        updated = true;
        read_idx = next_idx;
    }
    if(mMovie.mQuit.load(std::memory_order_relaxed))
    {
        if(mEOS)
            mFinalUpdate = true;
        mPictQRead.store(read_idx, std::memory_order_release);
        std::unique_lock<std::mutex>{mPictQMutex}.unlock();
        mPictQCond.notify_one();
        return;
    }

    if(updated)
    {
        mPictQRead.store(read_idx, std::memory_order_release);
        std::unique_lock<std::mutex>{mPictQMutex}.unlock();
        mPictQCond.notify_one();

        /* allocate or resize the buffer! */
        bool fmt_updated{false};
        if(!mImage || mWidth != mCodecCtx->width || mHeight != mCodecCtx->height)
        {
            fmt_updated = true;
            if(mImage)
                SDL_DestroyTexture(mImage);
            mImage = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING,
                mCodecCtx->coded_width, mCodecCtx->coded_height);
            if(!mImage)
                std::cerr<< "Failed to create YV12 texture!" <<std::endl;
            mWidth = mCodecCtx->width;
            mHeight = mCodecCtx->height;

            if(mFirstUpdate && mWidth > 0 && mHeight > 0)
            {
                /* For the first update, set the window size to the video size. */
                mFirstUpdate = false;

                int w{mWidth};
                int h{mHeight};
                if(mCodecCtx->sample_aspect_ratio.den != 0)
                {
                    double aspect_ratio = av_q2d(mCodecCtx->sample_aspect_ratio);
                    if(aspect_ratio >= 1.0)
                        w = static_cast<int>(w*aspect_ratio + 0.5);
                    else if(aspect_ratio > 0.0)
                        h = static_cast<int>(h/aspect_ratio + 0.5);
                }
                SDL_SetWindowSize(screen, w, h);
            }
        }

        if(mImage)
        {
            AVFrame *frame{vp->mFrame.get()};
            void *pixels{nullptr};
            int pitch{0};

            if(mCodecCtx->pix_fmt == AV_PIX_FMT_YUV420P)
                SDL_UpdateYUVTexture(mImage, nullptr,
                    frame->data[0], frame->linesize[0],
                    frame->data[1], frame->linesize[1],
                    frame->data[2], frame->linesize[2]
                );
            else if(SDL_LockTexture(mImage, nullptr, &pixels, &pitch) != 0)
                std::cerr<< "Failed to lock texture" <<std::endl;
            else
            {
                // Convert the image into YUV format that SDL uses
                int coded_w{mCodecCtx->coded_width};
                int coded_h{mCodecCtx->coded_height};
                int w{mCodecCtx->width};
                int h{mCodecCtx->height};
                if(!mSwscaleCtx || fmt_updated)
                {
                    mSwscaleCtx.reset(sws_getContext(
                        w, h, mCodecCtx->pix_fmt,
                        w, h, AV_PIX_FMT_YUV420P, 0,
                        nullptr, nullptr, nullptr
                    ));
                }

                /* point pict at the queue */
                uint8_t *pict_data[3];
                pict_data[0] = static_cast<uint8_t*>(pixels);
                pict_data[1] = pict_data[0] + coded_w*coded_h;
                pict_data[2] = pict_data[1] + coded_w*coded_h/4;

                int pict_linesize[3];
                pict_linesize[0] = pitch;
                pict_linesize[1] = pitch / 2;
                pict_linesize[2] = pitch / 2;

                sws_scale(mSwscaleCtx.get(), reinterpret_cast<uint8_t**>(frame->data), frame->linesize,
                    0, h, pict_data, pict_linesize);
                SDL_UnlockTexture(mImage);
            }
        }

        redraw = true;
    }

    if(redraw)
    {
        /* Show the picture! */
        display(screen, renderer);
    }

    if(updated)
    {
        auto disp_time = get_avtime();

        std::lock_guard<std::mutex> _{mDispPtsMutex};
        mDisplayPts = vp->mPts;
        mDisplayPtsTime = disp_time;
    }
    if(mEOS.load(std::memory_order_acquire))
    {
        if((read_idx+1)%mPictQ.size() == mPictQWrite.load(std::memory_order_acquire))
        {
            mFinalUpdate = true;
            std::unique_lock<std::mutex>{mPictQMutex}.unlock();
            mPictQCond.notify_one();
        }
    }
}

int VideoState::handler()
{
    std::for_each(mPictQ.begin(), mPictQ.end(),
        [](Picture &pict) -> void
        { pict.mFrame = AVFramePtr{av_frame_alloc()}; });

    /* Prefill the codec buffer. */
    do {
        const int ret{mPackets.sendTo(mCodecCtx.get())};
        if(ret == AVERROR(EAGAIN) || ret == AVErrorEOF)
            break;
    } while(1);

    {
        std::lock_guard<std::mutex> _{mDispPtsMutex};
        mDisplayPtsTime = get_avtime();
    }

    auto current_pts = nanoseconds::zero();
    while(!mMovie.mQuit.load(std::memory_order_relaxed))
    {
        size_t write_idx{mPictQWrite.load(std::memory_order_relaxed)};
        Picture *vp{&mPictQ[write_idx]};

        /* Retrieve video frame. */
        AVFrame *decoded_frame{vp->mFrame.get()};
        int ret;
        while((ret=avcodec_receive_frame(mCodecCtx.get(), decoded_frame)) == AVERROR(EAGAIN))
            mPackets.sendTo(mCodecCtx.get());
        if(ret != 0)
        {
            if(ret == AVErrorEOF) break;
            std::cerr<< "Failed to receive frame: "<<ret <<std::endl;
            continue;
        }

        /* Get the PTS for this frame. */
        if(decoded_frame->best_effort_timestamp != AVNoPtsValue)
            current_pts = duration_cast<nanoseconds>(seconds_d64{av_q2d(mStream->time_base) *
                static_cast<double>(decoded_frame->best_effort_timestamp)});
        vp->mPts = current_pts;

        /* Update the video clock to the next expected PTS. */
        auto frame_delay = av_q2d(mCodecCtx->time_base);
        frame_delay += decoded_frame->repeat_pict * (frame_delay * 0.5);
        current_pts += duration_cast<nanoseconds>(seconds_d64{frame_delay});

        /* Put the frame in the queue to be loaded into a texture and displayed
         * by the rendering thread.
         */
        write_idx = (write_idx+1)%mPictQ.size();
        mPictQWrite.store(write_idx, std::memory_order_release);

        /* Send a packet now so it's hopefully ready by the time it's needed. */
        mPackets.sendTo(mCodecCtx.get());

        if(write_idx == mPictQRead.load(std::memory_order_acquire))
        {
            /* Wait until we have space for a new pic */
            std::unique_lock<std::mutex> lock{mPictQMutex};
            while(write_idx == mPictQRead.load(std::memory_order_acquire) &&
                !mMovie.mQuit.load(std::memory_order_relaxed))
                mPictQCond.wait(lock);
        }
    }
    mEOS = true;

    std::unique_lock<std::mutex> lock{mPictQMutex};
    while(!mFinalUpdate) mPictQCond.wait(lock);

    return 0;
}


int MovieState::decode_interrupt_cb(void *ctx)
{
    return static_cast<MovieState*>(ctx)->mQuit.load(std::memory_order_relaxed);
}

bool MovieState::prepare()
{
    AVIOContext *avioctx{nullptr};
    AVIOInterruptCB intcb{decode_interrupt_cb, this};
    if(avio_open2(&avioctx, mFilename.c_str(), AVIO_FLAG_READ, &intcb, nullptr))
    {
        std::cerr<< "Failed to open "<<mFilename <<std::endl;
        return false;
    }
    mIOContext.reset(avioctx);

    /* Open movie file. If avformat_open_input fails it will automatically free
     * this context, so don't set it onto a smart pointer yet.
     */
    AVFormatContext *fmtctx{avformat_alloc_context()};
    fmtctx->pb = mIOContext.get();
    fmtctx->interrupt_callback = intcb;
    if(avformat_open_input(&fmtctx, mFilename.c_str(), nullptr, nullptr) != 0)
    {
        std::cerr<< "Failed to open "<<mFilename <<std::endl;
        return false;
    }
    mFormatCtx.reset(fmtctx);

    /* Retrieve stream information */
    if(avformat_find_stream_info(mFormatCtx.get(), nullptr) < 0)
    {
        std::cerr<< mFilename<<": failed to find stream info" <<std::endl;
        return false;
    }

    /* Dump information about file onto standard error */
    av_dump_format(mFormatCtx.get(), 0, mFilename.c_str(), 0);

    mParseThread = std::thread{std::mem_fn(&MovieState::parse_handler), this};
    return true;
}

void MovieState::setTitle(SDL_Window *window)
{
    auto pos1 = mFilename.rfind('/');
    auto pos2 = mFilename.rfind('\\');
    auto fpos = ((pos1 == std::string::npos) ? pos2 :
                 (pos2 == std::string::npos) ? pos1 :
                 std::max(pos1, pos2)) + 1;
    SDL_SetWindowTitle(window, (mFilename.substr(fpos)+" - "+AppName).c_str());
}

nanoseconds MovieState::getClock()
{
    if(mClockBase == microseconds::min())
        return nanoseconds::zero();
    return get_avtime() - mClockBase;
}

nanoseconds MovieState::getMasterClock()
{
    if(mAVSyncType == SyncMaster::Video)
        return mVideo.getClock();
    if(mAVSyncType == SyncMaster::Audio)
        return mAudio.getClock();
    return getClock();
}

nanoseconds MovieState::getDuration()
{ return std::chrono::duration<int64_t,std::ratio<1,AV_TIME_BASE>>(mFormatCtx->duration); }

int MovieState::streamComponentOpen(unsigned int stream_index)
{
    if(stream_index >= mFormatCtx->nb_streams)
        return -1;

    /* Get a pointer to the codec context for the stream, and open the
     * associated codec.
     */
    AVCodecCtxPtr avctx{avcodec_alloc_context3(nullptr)};
    if(!avctx) return -1;

    if(avcodec_parameters_to_context(avctx.get(), mFormatCtx->streams[stream_index]->codecpar))
        return -1;

    AVCodec *codec{avcodec_find_decoder(avctx->codec_id)};
    if(!codec || avcodec_open2(avctx.get(), codec, nullptr) < 0)
    {
        std::cerr<< "Unsupported codec: "<<avcodec_get_name(avctx->codec_id)
            << " (0x"<<std::hex<<avctx->codec_id<<std::dec<<")" <<std::endl;
        return -1;
    }

    /* Initialize and start the media type handler */
    switch(avctx->codec_type)
    {
        case AVMEDIA_TYPE_AUDIO:
            mAudio.mStream = mFormatCtx->streams[stream_index];
            mAudio.mCodecCtx = std::move(avctx);
            break;

        case AVMEDIA_TYPE_VIDEO:
            mVideo.mStream = mFormatCtx->streams[stream_index];
            mVideo.mCodecCtx = std::move(avctx);
            break;

        default:
            return -1;
    }

    return static_cast<int>(stream_index);
}

int MovieState::parse_handler()
{
    auto &audio_queue = mAudio.mPackets;
    auto &video_queue = mVideo.mPackets;

    int video_index{-1};
    int audio_index{-1};

    /* Find the first video and audio streams */
    for(unsigned int i{0u};i < mFormatCtx->nb_streams;i++)
    {
        auto codecpar = mFormatCtx->streams[i]->codecpar;
        if(codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !DisableVideo && video_index < 0)
            video_index = streamComponentOpen(i);
        else if(codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audio_index < 0)
            audio_index = streamComponentOpen(i);
    }

    if(video_index < 0 && audio_index < 0)
    {
        std::cerr<< mFilename<<": could not open codecs" <<std::endl;
        mQuit = true;
    }

    /* Set the base time 750ms ahead of the current av time. */
    mClockBase = get_avtime() + milliseconds{750};

    if(audio_index >= 0)
        mAudioThread = std::thread{std::mem_fn(&AudioState::handler), &mAudio};
    if(video_index >= 0)
        mVideoThread = std::thread{std::mem_fn(&VideoState::handler), &mVideo};

    /* Main packet reading/dispatching loop */
    while(!mQuit.load(std::memory_order_relaxed))
    {
        AVPacket packet;
        if(av_read_frame(mFormatCtx.get(), &packet) < 0)
            break;

        /* Copy the packet into the queue it's meant for. */
        if(packet.stream_index == video_index)
        {
            while(!mQuit.load(std::memory_order_acquire) && !video_queue.put(&packet))
                std::this_thread::sleep_for(milliseconds{100});
        }
        else if(packet.stream_index == audio_index)
        {
            while(!mQuit.load(std::memory_order_acquire) && !audio_queue.put(&packet))
                std::this_thread::sleep_for(milliseconds{100});
        }

        av_packet_unref(&packet);
    }
    /* Finish the queues so the receivers know nothing more is coming. */
    if(mVideo.mCodecCtx) video_queue.setFinished();
    if(mAudio.mCodecCtx) audio_queue.setFinished();

    /* all done - wait for it */
    if(mVideoThread.joinable())
        mVideoThread.join();
    if(mAudioThread.joinable())
        mAudioThread.join();

    mVideo.mEOS = true;
    std::unique_lock<std::mutex> lock{mVideo.mPictQMutex};
    while(!mVideo.mFinalUpdate)
        mVideo.mPictQCond.wait(lock);
    lock.unlock();

    SDL_Event evt{};
    evt.user.type = FF_MOVIE_DONE_EVENT;
    SDL_PushEvent(&evt);

    return 0;
}


// Helper class+method to print the time with human-readable formatting.
struct PrettyTime {
    seconds mTime;
};
std::ostream &operator<<(std::ostream &os, const PrettyTime &rhs)
{
    using hours = std::chrono::hours;
    using minutes = std::chrono::minutes;

    seconds t{rhs.mTime};
    if(t.count() < 0)
    {
        os << '-';
        t *= -1;
    }

    // Only handle up to hour formatting
    if(t >= hours{1})
        os << duration_cast<hours>(t).count() << 'h' << std::setfill('0') << std::setw(2)
           << (duration_cast<minutes>(t).count() % 60) << 'm';
    else
        os << duration_cast<minutes>(t).count() << 'm' << std::setfill('0');
    os << std::setw(2) << (duration_cast<seconds>(t).count() % 60) << 's' << std::setw(0)
       << std::setfill(' ');
    return os;
}

} // namespace


int main(int argc, char *argv[])
{
    std::unique_ptr<MovieState> movState;

    if(argc < 2)
    {
        std::cerr<< "Usage: "<<argv[0]<<" [-device <device name>] [-direct] <files...>" <<std::endl;
        return 1;
    }
    /* Register all formats and codecs */
#if !(LIBAVFORMAT_VERSION_INT >= AV_VERSION_INT(58, 9, 100))
    av_register_all();
#endif
    /* Initialize networking protocols */
    avformat_network_init();

    if(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS))
    {
        std::cerr<< "Could not initialize SDL - <<"<<SDL_GetError() <<std::endl;
        return 1;
    }

    /* Make a window to put our video */
    SDL_Window *screen{SDL_CreateWindow(AppName.c_str(), 0, 0, 640, 480, SDL_WINDOW_RESIZABLE)};
    if(!screen)
    {
        std::cerr<< "SDL: could not set video mode - exiting" <<std::endl;
        return 1;
    }
    /* Make a renderer to handle the texture image surface and rendering. */
    Uint32 render_flags{SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC};
    SDL_Renderer *renderer{SDL_CreateRenderer(screen, -1, render_flags)};
    if(renderer)
    {
        SDL_RendererInfo rinf{};
        bool ok{false};

        /* Make sure the renderer supports IYUV textures. If not, fallback to a
         * software renderer. */
        if(SDL_GetRendererInfo(renderer, &rinf) == 0)
        {
            for(Uint32 i{0u};!ok && i < rinf.num_texture_formats;i++)
                ok = (rinf.texture_formats[i] == SDL_PIXELFORMAT_IYUV);
        }
        if(!ok)
        {
            std::cerr<< "IYUV pixelformat textures not supported on renderer "<<rinf.name <<std::endl;
            SDL_DestroyRenderer(renderer);
            renderer = nullptr;
        }
    }
    if(!renderer)
    {
        render_flags = SDL_RENDERER_SOFTWARE | SDL_RENDERER_PRESENTVSYNC;
        renderer = SDL_CreateRenderer(screen, -1, render_flags);
    }
    if(!renderer)
    {
        std::cerr<< "SDL: could not create renderer - exiting" <<std::endl;
        return 1;
    }
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderFillRect(renderer, nullptr);
    SDL_RenderPresent(renderer);

    /* Open an audio device */
    ++argv; --argc;
    if(InitAL(&argv, &argc))
    {
        std::cerr<< "Failed to set up audio device" <<std::endl;
        return 1;
    }

    {
        auto device = alcGetContextsDevice(alcGetCurrentContext());
        if(alcIsExtensionPresent(device, "ALC_SOFT_device_clock"))
        {
            std::cout<< "Found ALC_SOFT_device_clock" <<std::endl;
            alcGetInteger64vSOFT = reinterpret_cast<LPALCGETINTEGER64VSOFT>(
                alcGetProcAddress(device, "alcGetInteger64vSOFT")
            );
        }
    }

    if(alIsExtensionPresent("AL_SOFT_source_latency"))
    {
        std::cout<< "Found AL_SOFT_source_latency" <<std::endl;
        alGetSourcei64vSOFT = reinterpret_cast<LPALGETSOURCEI64VSOFT>(
            alGetProcAddress("alGetSourcei64vSOFT")
        );
    }
#ifdef AL_SOFT_events
    if(alIsExtensionPresent("AL_SOFT_events"))
    {
        std::cout<< "Found AL_SOFT_events" <<std::endl;
        alEventControlSOFT = reinterpret_cast<LPALEVENTCONTROLSOFT>(
            alGetProcAddress("alEventControlSOFT"));
        alEventCallbackSOFT = reinterpret_cast<LPALEVENTCALLBACKSOFT>(
            alGetProcAddress("alEventCallbackSOFT"));
    }
#endif
#ifdef AL_SOFT_callback_buffer
    if(alIsExtensionPresent("AL_SOFTX_callback_buffer"))
    {
        std::cout<< "Found AL_SOFT_callback_buffer" <<std::endl;
        alBufferCallbackSOFT = reinterpret_cast<LPALBUFFERCALLBACKSOFT>(
            alGetProcAddress("alBufferCallbackSOFT"));
    }
#endif

    int fileidx{0};
    for(;fileidx < argc;++fileidx)
    {
        if(strcmp(argv[fileidx], "-direct") == 0)
        {
            if(alIsExtensionPresent("AL_SOFT_direct_channels_remix"))
            {
                std::cout<< "Found AL_SOFT_direct_channels_remix" <<std::endl;
                DirectOutMode = AL_REMIX_UNMATCHED_SOFT;
            }
            else if(alIsExtensionPresent("AL_SOFT_direct_channels"))
            {
                std::cout<< "Found AL_SOFT_direct_channels" <<std::endl;
                DirectOutMode = AL_DROP_UNMATCHED_SOFT;
            }
            else
                std::cerr<< "AL_SOFT_direct_channels not supported for direct output" <<std::endl;
        }
        else if(strcmp(argv[fileidx], "-wide") == 0)
        {
            if(!alIsExtensionPresent("AL_EXT_STEREO_ANGLES"))
                std::cerr<< "AL_EXT_STEREO_ANGLES not supported for wide stereo" <<std::endl;
            else
            {
                std::cout<< "Found AL_EXT_STEREO_ANGLES" <<std::endl;
                EnableWideStereo = true;
            }
        }
        else if(strcmp(argv[fileidx], "-novideo") == 0)
            DisableVideo = true;
        else
            break;
    }

    while(fileidx < argc && !movState)
    {
        movState = std::unique_ptr<MovieState>{new MovieState{argv[fileidx++]}};
        if(!movState->prepare()) movState = nullptr;
    }
    if(!movState)
    {
        std::cerr<< "Could not start a video" <<std::endl;
        return 1;
    }
    movState->setTitle(screen);

    /* Default to going to the next movie at the end of one. */
    enum class EomAction {
        Next, Quit
    } eom_action{EomAction::Next};
    seconds last_time{seconds::min()};
    while(1)
    {
        SDL_Event event{};
        int have_evt{SDL_WaitEventTimeout(&event, 10)};

        auto cur_time = std::chrono::duration_cast<seconds>(movState->getMasterClock());
        if(cur_time != last_time)
        {
            auto end_time = std::chrono::duration_cast<seconds>(movState->getDuration());
            std::cout<< "    \r "<<PrettyTime{cur_time}<<" / "<<PrettyTime{end_time} <<std::flush;
            last_time = cur_time;
        }

        bool force_redraw{false};
        if(have_evt) do {
            switch(event.type)
            {
            case SDL_KEYDOWN:
                switch(event.key.keysym.sym)
                {
                case SDLK_ESCAPE:
                    movState->mQuit = true;
                    eom_action = EomAction::Quit;
                    break;

                case SDLK_n:
                    movState->mQuit = true;
                    eom_action = EomAction::Next;
                    break;

                default:
                    break;
                }
                break;

            case SDL_WINDOWEVENT:
                switch(event.window.event)
                {
                case SDL_WINDOWEVENT_RESIZED:
                    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
                    SDL_RenderFillRect(renderer, nullptr);
                    force_redraw = true;
                    break;

                case SDL_WINDOWEVENT_EXPOSED:
                    force_redraw = true;
                    break;

                default:
                    break;
                }
                break;

            case SDL_QUIT:
                movState->mQuit = true;
                eom_action = EomAction::Quit;
                break;

            case FF_MOVIE_DONE_EVENT:
                std::cout<<'\n';
                last_time = seconds::min();
                if(eom_action != EomAction::Quit)
                {
                    movState = nullptr;
                    while(fileidx < argc && !movState)
                    {
                        movState = std::unique_ptr<MovieState>{new MovieState{argv[fileidx++]}};
                        if(!movState->prepare()) movState = nullptr;
                    }
                    if(movState)
                    {
                        movState->setTitle(screen);
                        break;
                    }
                }

                /* Nothing more to play. Shut everything down and quit. */
                movState = nullptr;

                CloseAL();

                SDL_DestroyRenderer(renderer);
                renderer = nullptr;
                SDL_DestroyWindow(screen);
                screen = nullptr;

                SDL_Quit();
                exit(0);

            default:
                break;
            }
        } while(SDL_PollEvent(&event));

        movState->mVideo.updateVideo(screen, renderer, force_redraw);
    }

    std::cerr<< "SDL_WaitEvent error - "<<SDL_GetError() <<std::endl;
    return 1;
}
