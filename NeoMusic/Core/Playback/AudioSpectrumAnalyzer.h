#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface AudioSpectrumAnalyzer : NSObject
- (void)addConsumer;
- (void)removeConsumer;
- (void)consumeBuffer:(AVAudioPCMBuffer *)buffer NS_SWIFT_NAME(consume(_:));
- (BOOL)attachToItem:(AVPlayerItem *)item track:(AVAssetTrack *)track;
- (float)levelAtIndex:(NSInteger)index;
- (unsigned long)sampleCount;
+ (NSArray<NSNumber *> *)levelsForPCM:(NSData *)pcm sampleRate:(double)rate;
@end
NS_ASSUME_NONNULL_END
