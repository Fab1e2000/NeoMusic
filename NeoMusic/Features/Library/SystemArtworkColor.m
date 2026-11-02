#import "SystemArtworkColor.h"
#import <objc/message.h>
#import <dlfcn.h>

UIColor *SystemArtworkBackgroundColor(UIImage *image) {
    @try {
        static void *framework;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            framework = dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_NOW);
        });
        if (!framework) return nil;
        Class analyzer = NSClassFromString(@"MPArtworkColorAnalyzer");
        SEL initializer = NSSelectorFromString(@"initWithImage:");
        SEL analyze = NSSelectorFromString(@"analyze");
        SEL background = NSSelectorFromString(@"backgroundColor");
        if (!analyzer || ![analyzer instancesRespondToSelector:initializer] ||
            ![analyzer instancesRespondToSelector:analyze]) return nil;
        id instance = ((id (*)(id, SEL, id))objc_msgSend)([analyzer alloc], initializer, image);
        id result = ((id (*)(id, SEL))objc_msgSend)(instance, analyze);
        if (![result respondsToSelector:background]) return nil;
        id color = ((id (*)(id, SEL))objc_msgSend)(result, background);
        if (![color isKindOfClass:UIColor.class]) return nil;
        return color;
    } @catch (NSException *exception) {
        return nil;
    }
}
