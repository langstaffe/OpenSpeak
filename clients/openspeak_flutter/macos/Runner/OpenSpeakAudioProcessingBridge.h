#import <FlutterMacOS/FlutterMacOS.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenSpeakAudioProcessingBridge : NSObject

+ (void)registerWithBinaryMessenger:(id<FlutterBinaryMessenger>)messenger
    NS_SWIFT_NAME(register(with:));

@end

NS_ASSUME_NONNULL_END
