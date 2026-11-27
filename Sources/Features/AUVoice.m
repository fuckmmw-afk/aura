#import "AUVoice.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import "Core/AUCore.h"
#import "Features/AUVoiceDSP.h"
#import "Vendor/fishhook.h"

// The ring the render thread fills: the centre (mid) and the sides of the mix, mono each.
enum { kRing = 1 << 17, kRingMask = kRing - 1, kBlocks = 512, kQueue = 64 };

static float gMid[kRing], gSide[kRing];
static _Atomic uint64_t gWritten;              // samples written since launch
typedef struct {
    uint64_t start, host;                      // the block's first sample and its mHostTime
} AUVBlock;
static AUVBlock gBlockRing[kBlocks];
static _Atomic uint64_t gBlockCount;
static _Atomic bool gWanted, gInstalled;
static _Atomic uint64_t gLayout;               // flags | channels << 32 | bytes << 48, 0 unusable
static _Atomic uint64_t gRateBits;
static _Atomic uint64_t gLastAudioHost;
static _Atomic uint64_t gOnsetCount;
static _Atomic uint64_t gSensitivityBits;
static OSStatus (*gStart)(AudioUnit);

static double hostSeconds(uint64_t host) {
    static mach_timebase_info_data_t base;
    if (!base.denom) mach_timebase_info(&base);
    return (double)host * base.numer / base.denom / 1e9;
}

#pragma mark - the render thread

static inline float sampleAt(const void *data, uint32_t index, uint32_t bytes, bool isFloat) {
    if (isFloat && bytes == 4) return ((const float *)data)[index];
    if (!isFloat && bytes == 2) return ((const int16_t *)data)[index] / 32768.0f;
    if (!isFloat && bytes == 4) return ((const int32_t *)data)[index] / 2147483648.0f;
    return 0;
}

static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                         UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    if (!atomic_load_explicit(&gWanted, memory_order_relaxed)) return noErr;
    uint64_t layout = atomic_load_explicit(&gLayout, memory_order_relaxed);
    if (!layout) return noErr;
    uint32_t formatFlags = (uint32_t)layout, channels = (uint32_t)(layout >> 32) & 0xffff, bytes = (uint32_t)(layout >> 48);
    bool isFloat = formatFlags & kAudioFormatFlagIsFloat;
    bool interleaved = !(formatFlags & kAudioFormatFlagIsNonInterleaved);
    uint64_t at = atomic_load_explicit(&gWritten, memory_order_relaxed);
    if (frames > kRing / 4) frames = kRing / 4;
    if (interleaved) {
        const void *buffer = data->mBuffers[0].mData;
        if (!buffer) return noErr;
        uint32_t stride = MAX(1u, data->mBuffers[0].mNumberChannels ?: channels);
        for (uint32_t i = 0; i < frames; i++) {
            float l = sampleAt(buffer, i * stride, bytes, isFloat);
            float r = stride > 1 ? sampleAt(buffer, i * stride + 1, bytes, isFloat) : l;
            gMid[(at + i) & kRingMask] = (l + r) * 0.5f;
            gSide[(at + i) & kRingMask] = (l - r) * 0.5f;
        }
    } else {
        const void *left = data->mBuffers[0].mData;
        const void *right = data->mNumberBuffers > 1 ? data->mBuffers[1].mData : left;
        if (!left || !right) return noErr;
        for (uint32_t i = 0; i < frames; i++) {
            float l = sampleAt(left, i, bytes, isFloat), r = sampleAt(right, i, bytes, isFloat);
            gMid[(at + i) & kRingMask] = (l + r) * 0.5f;
            gSide[(at + i) & kRingMask] = (l - r) * 0.5f;
        }
    }
    uint64_t block = atomic_load_explicit(&gBlockCount, memory_order_relaxed);
    gBlockRing[block % kBlocks] = (AUVBlock){at, (timestamp && (timestamp->mFlags & kAudioTimeStampHostTimeValid)) ? timestamp->mHostTime : mach_absolute_time()};
    atomic_store_explicit(&gBlockCount, block + 1, memory_order_release);
    atomic_store_explicit(&gWritten, at + frames, memory_order_release);
    if (!(*flags & kAudioUnitRenderAction_OutputIsSilence)) atomic_store_explicit(&gLastAudioHost, mach_absolute_time(), memory_order_relaxed);
    return noErr;
}

static BOOL isRemoteIO(AudioUnit unit) {
    AudioComponentDescription description = {0};
    return unit && AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) == noErr &&
           description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO;
}

static void updateFormat(AudioUnit unit) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, &size) != noErr ||
        format.mFormatID != kAudioFormatLinearPCM || (format.mBitsPerChannel != 16 && format.mBitsPerChannel != 32) ||
        format.mSampleRate < 8000 || format.mChannelsPerFrame < 1) {
        atomic_store(&gLayout, 0);
        AULog(@"voice: the output's format is not one to read (id %u, %u bits, %.0f Hz)", (unsigned)format.mFormatID,
              (unsigned)format.mBitsPerChannel, format.mSampleRate);
        return;
    }
    uint64_t rateBits;
    memcpy(&rateBits, &format.mSampleRate, sizeof rateBits);
    atomic_store(&gRateBits, rateBits);
    atomic_store(&gLayout, (uint64_t)format.mFormatFlags | (uint64_t)(format.mChannelsPerFrame & 0xffff) << 32 |
                               (uint64_t)(format.mBitsPerChannel / 8) << 48);
    AULog(@"voice: listening at %.0f Hz, %u ch, %u bit %@ %@", format.mSampleRate, (unsigned)format.mChannelsPerFrame,
          (unsigned)format.mBitsPerChannel, (format.mFormatFlags & kAudioFormatFlagIsFloat) ? @"float" : @"int",
          (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? @"planar" : @"interleaved");
}

static void formatChanged(void *refCon, AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element) {
    if (property == kAudioUnitProperty_StreamFormat && element == 0) updateFormat(unit);
}

static OSStatus startOutput(AudioUnit unit) {
    OSStatus status = gStart ? gStart(unit) : -1;
    if (status == noErr && isRemoteIO(unit)) {
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat, formatChanged, NULL);
        AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, formatChanged, NULL);
        updateFormat(unit);
        AudioUnitRemoveRenderNotify(unit, rendered, NULL);
        AudioUnitAddRenderNotify(unit, rendered, NULL);
        if (!atomic_exchange(&gInstalled, true)) AULog(@"voice: the output unit is tapped (read only)");
    }
    return status;
}

void AUVoiceInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        double one = 1;
        uint64_t bits;
        memcpy(&bits, &one, sizeof bits);
        atomic_store(&gSensitivityBits, bits);
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const struct mach_header *header = _dyld_get_image_header(i);
            if (!header || header->filetype != MH_EXECUTE) continue;
            struct rebinding rebinding = {"AudioOutputUnitStart", (void *)startOutput, (void **)&gStart};
            rebind_symbols_image((void *)header, _dyld_get_image_vmaddr_slide(i), &rebinding, 1);
            break;
        }
        if (!gStart) AULog(@"voice: the app does not import AudioOutputUnitStart; no ear for the typewriter");
    });
}

BOOL AUVoiceInstalled(void) {
    return atomic_load(&gInstalled);
}

#pragma mark - the listening queue

static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static CFTimeInterval gOnsets[kQueue];
static NSUInteger gOnsetHead, gOnsetTail;
static _Atomic uint64_t gLatencyBits;

static AUVoiceDSP *gDSP;

static double latencySeconds(void) {
    uint64_t bits = atomic_load(&gLatencyBits);
    double latency;
    memcpy(&latency, &bits, sizeof latency);
    return latency;
}

// A syllable found at `sample`: when it will be heard, from the block it was rendered in.
static void pushOnset(uint64_t sample, double rate, void *context) {
    uint64_t count = atomic_load_explicit(&gBlockCount, memory_order_acquire);
    double heard = 0;
    for (uint64_t b = count; b > 0 && count - b < kBlocks; b--) {
        AUVBlock block = gBlockRing[(b - 1) % kBlocks];
        if (block.start <= sample) {
            heard = hostSeconds(block.host) + (double)(sample - block.start) / rate + latencySeconds();
            break;
        }
    }
    if (heard <= 0) return;
    os_unfair_lock_lock(&gLock);
    gOnsets[gOnsetTail % kQueue] = heard;
    gOnsetTail++;
    if (gOnsetTail - gOnsetHead > kQueue) gOnsetHead = gOnsetTail - kQueue;
    os_unfair_lock_unlock(&gLock);
    atomic_fetch_add(&gOnsetCount, 1);
}

static void listen(void) {
    uint64_t rateBits = atomic_load(&gRateBits), sensitivityBits = atomic_load(&gSensitivityBits);
    double rate, sensitivity;
    memcpy(&rate, &rateBits, sizeof rate);
    memcpy(&sensitivity, &sensitivityBits, sizeof sensitivity);
    uint64_t written = atomic_load_explicit(&gWritten, memory_order_acquire);
    AUVoiceDSPRun(gDSP, gMid, gSide, kRingMask, written, rate, sensitivity, pushOnset, NULL);
}

static void readLatency(void) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    double latency = session.outputLatency;
    if (!(latency >= 0 && latency < 1)) latency = 0;
    uint64_t bits;
    memcpy(&bits, &latency, sizeof bits);
    atomic_store(&gLatencyBits, bits);
}

void AUVoiceSetWanted(BOOL wanted) {
    if (wanted == atomic_load(&gWanted)) return;
    atomic_store(&gWanted, wanted);
    if (!gQueue) {
        gQueue = dispatch_queue_create("aura.voice", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        gDSP = AUVoiceDSPCreate();
        readLatency();
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { readLatency(); }];
    }
    if (wanted) {
        readLatency();
        if (!gTimer) {
            gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
            dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(gTimer, ^{ listen(); });
            dispatch_resume(gTimer);
        }
        AULog(@"voice: listening for syllables (output latency %.0f ms, tap %@)", latencySeconds() * 1000, AUVoiceInstalled() ? @"in place" : @"not yet");
    } else if (gTimer) {
        dispatch_source_cancel(gTimer);
        gTimer = nil;
    }
}

BOOL AUVoiceHearing(void) {
    uint64_t last = atomic_load(&gLastAudioHost);
    return last && atomic_load(&gWanted) && hostSeconds(mach_absolute_time() - last) < 1.5;
}

NSUInteger AUVoiceTakeOnsets(CFTimeInterval now, CFTimeInterval *times, NSUInteger capacity) {
    NSUInteger taken = 0;
    os_unfair_lock_lock(&gLock);
    while (gOnsetHead < gOnsetTail && taken < capacity) {
        CFTimeInterval heard = gOnsets[gOnsetHead % kQueue];
        if (heard > now) break;
        times[taken++] = heard;
        gOnsetHead++;
    }
    os_unfair_lock_unlock(&gLock);
    return taken;
}

void AUVoiceClear(void) {
    os_unfair_lock_lock(&gLock);
    gOnsetHead = gOnsetTail;
    os_unfair_lock_unlock(&gLock);
}

void AUVoiceSetSensitivity(double sensitivity) {
    uint64_t bits;
    memcpy(&bits, &sensitivity, sizeof bits);
    atomic_store(&gSensitivityBits, bits);
}

uint64_t AUVoiceOnsetCount(void) {
    return atomic_load(&gOnsetCount);
}
