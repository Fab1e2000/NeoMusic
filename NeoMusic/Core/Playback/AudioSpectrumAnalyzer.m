#import "AudioSpectrumAnalyzer.h"
#import <MediaToolbox/MediaToolbox.h>
#import <Accelerate/Accelerate.h>
#import <stdatomic.h>
#define N 2048
// Tap owns this storage. No allocation, locks, UI work, or dispatch in process().
typedef struct {
    FFTSetup fft;
    float window[N], input[N], work[N], real[N/2], imag[N/2], power[N/2];
    float ceiling, displayed[5];
    int hop;
    int filled;
    double rate;
    BOOL supported;
    _Atomic(float) levels[5];
    _Atomic(unsigned long) samples;
} Analysis;
// Band boundaries from echoghi/v5 (MIT); amplitude follows SpectrumCompareLab C.
// A common reference preserves relative band energy; no per-band normalization.
static void initializeWindow(Analysis *s) {
    vDSP_hann_window(s->window,N,vDSP_HANN_NORM);
    s->ceiling=-20;
    s->hop=MAX(1,MIN(N,(int)lround(s->rate/60)));
}
static void analyze(Analysis *s) {
    vDSP_vmul(s->input,1,s->window,1,s->work,1,N);
    DSPSplitComplex z={s->real,s->imag};
    vDSP_ctoz((DSPComplex *)s->work,2,&z,1,N/2);
    vDSP_fft_zrip(s->fft,&z,1,11,FFT_FORWARD);
    s->imag[0]=0;
    vDSP_zvmags(&z,1,s->power,1,N/2);
    const float edges[]={20,120,300,900,3000,12000};
    float db[5], loudest=-140;
    for(int b=0;b<5;b++) {
        int lo=MAX(1,(int)floor(edges[b]*N/s->rate));
        int hi=MIN(N/2-1,(int)ceil(edges[b+1]*N/s->rate));
        float sum=0;
        for(int k=lo;k<=hi;k++) sum+=s->power[k];
        // Keep the demo's Hann/vDSP magnitude scale so its reference and gate
        // have the same meaning. This is a display scale, not calibrated dBFS.
        db[b]=20*log10f(fmaxf(sqrtf(sum)/N,1e-7f));
        loudest=fmaxf(loudest,db[b]);
    }
    float dt=(float)s->hop/s->rate;
    s->ceiling=fmaxf(-35,fmaxf(loudest,s->ceiling-dt*3));
    for(int b=0;b<5;b++) {
        float target=db[b]<-65 ? 0 : powf(fmaxf(0,(db[b]-s->ceiling+24)/32),1.6f);
        target=fminf(1,target);
        float tau=target>s->displayed[b] ? 0.025f : 0.170f;
        float alpha=1-expf(-dt/tau);
        s->displayed[b]+=(target-s->displayed[b])*alpha;
        atomic_store(&s->levels[b],s->displayed[b]);
    }
}
static void initTap(MTAudioProcessingTapRef tap, void *client, void **storage) {*storage=client;}
static void finalizeTap(MTAudioProcessingTapRef tap) {
    Analysis *s=MTAudioProcessingTapGetStorage(tap);
    vDSP_destroy_fftsetup(s->fft); free(s);
}
static void prepareTap(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *f) {
    Analysis *s=MTAudioProcessingTapGetStorage(tap);
    s->rate=f->mSampleRate;
    s->supported=f->mFormatID==kAudioFormatLinearPCM && (f->mFormatFlags & kAudioFormatFlagIsFloat) && f->mBitsPerChannel==32;
    s->filled=0;
    s->hop=MAX(1,MIN(N,(int)lround(s->rate/60)));
    s->ceiling=-20;
    memset(s->displayed,0,sizeof(s->displayed));
    for(int i=0;i<5;i++) atomic_store(&s->levels[i],0);
}
static void processTap(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags, AudioBufferList *buffers, CMItemCount *outFrames, MTAudioProcessingTapFlags *outFlags) {
    if(MTAudioProcessingTapGetSourceAudio(tap,frames,buffers,outFlags,NULL,outFrames)!=noErr) { *outFrames=0; return; }
    Analysis *s=MTAudioProcessingTapGetStorage(tap);
    if(!s->supported || !buffers->mNumberBuffers) return;
    // Downmix for analysis only; playback buffers pass through untouched.
    for(int i=0;i<*outFrames;i++) {
        float mono=0;
        int count=0;
        for (UInt32 b=0;b<buffers->mNumberBuffers;b++) {
            const AudioBuffer *buffer=&buffers->mBuffers[b];
            const float *data=buffer->mData;
            if (!data) continue;
            for (UInt32 c=0;c<buffer->mNumberChannels;c++) {
                mono+=data[i*buffer->mNumberChannels+c]; count++;
            }
        }
        s->input[s->filled++]=count ? mono/count : 0;
        if(s->filled==N) {
            analyze(s);
            // Run the demo mapping at about 60 Hz with
            // overlapping windows, independently of audio callback block size.
            memmove(s->input,s->input+s->hop,(N-s->hop)*sizeof(float));
            s->filled=N-s->hop;
        }
    }
    atomic_fetch_add(&s->samples,*outFrames);
}
@implementation AudioSpectrumAnalyzer {
    MTAudioProcessingTapRef _tap;
    Analysis *_state;
}
- (BOOL)attachToItem:(AVPlayerItem *)item track:(AVAssetTrack *)track {
    if(_tap || item.audioMix != nil) return NO;
    Analysis *s=calloc(1,sizeof(Analysis));
    if (!s) return NO;
    s->fft=vDSP_create_fftsetup(11,kFFTRadix2);
    if (!s->fft) { free(s); return NO; }
    initializeWindow(s);
    MTAudioProcessingTapCallbacks callbacks={kMTAudioProcessingTapCallbacksVersion_0,s,initTap,finalizeTap,prepareTap,NULL,processTap};
    if(MTAudioProcessingTapCreate(kCFAllocatorDefault,&callbacks,kMTAudioProcessingTapCreationFlag_PostEffects,&_tap)!=noErr) {
        vDSP_destroy_fftsetup(s->fft); free(s); return NO;
    }
    _state=s;
    AVMutableAudioMixInputParameters *parameters=[AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    parameters.audioTapProcessor=_tap;
    AVMutableAudioMix *mix=[AVMutableAudioMix audioMix]; mix.inputParameters=@[parameters]; item.audioMix=mix;
    return YES;
}
- (float)levelAtIndex:(NSInteger)i { return _state && i>=0 && i<5 ? atomic_load(&_state->levels[i]):0; }
- (unsigned long)sampleCount { return _state?atomic_load(&_state->samples):0; }
+ (NSArray<NSNumber *> *)levelsForPCM:(NSData *)pcm sampleRate:(double)rate {
    if (rate <= 0 || pcm.length < N*sizeof(float)) return @[@0,@0,@0,@0,@0];
    Analysis *s=calloc(1,sizeof(Analysis));
    s->rate=rate; s->fft=vDSP_create_fftsetup(11,kFFTRadix2);
    initializeWindow(s);
    memcpy(s->input,pcm.bytes,N*sizeof(float)); analyze(s);
    NSArray *result=@[@(atomic_load(&s->levels[0])),@(atomic_load(&s->levels[1])),@(atomic_load(&s->levels[2])),@(atomic_load(&s->levels[3])),@(atomic_load(&s->levels[4]))];
    vDSP_destroy_fftsetup(s->fft); free(s); return result;
}
- (void)dealloc { if(_tap) CFRelease(_tap); }
@end
