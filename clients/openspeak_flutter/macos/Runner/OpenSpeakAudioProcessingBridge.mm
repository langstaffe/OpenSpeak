#import "OpenSpeakAudioProcessingBridge.h"

#import <flutter_webrtc/AudioManager.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <vector>

#include "rnnoise_processor.h"

@interface OpenSpeakCaptureProcessor : NSObject <ExternalAudioProcessingDelegate> {
 @private
  std::atomic<bool> _enabled;
  bool _appliedEnabled;
  std::vector<std::unique_ptr<OpenSpeakRnnoiseProcessor>> _processors;
}

- (void)setEnabled:(BOOL)enabled;

@end

@implementation OpenSpeakCaptureProcessor

- (instancetype)init {
  self = [super init];
  if (self) {
    _enabled.store(false, std::memory_order_relaxed);
    _appliedEnabled = false;
  }
  return self;
}

- (void)setEnabled:(BOOL)enabled {
  _enabled.store(enabled, std::memory_order_release);
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz
                                       channels:(size_t)channels {
  _processors.clear();
  _processors.reserve(channels);
  for (size_t channel = 0; channel < channels; ++channel) {
    auto processor = std::make_unique<OpenSpeakRnnoiseProcessor>();
    processor->Initialize(static_cast<int>(sampleRateHz), 1);
    _processors.push_back(std::move(processor));
  }
  _appliedEnabled = false;
}

- (void)audioProcessingProcess:(RTCAudioBuffer*)audioBuffer {
  const bool enabled = _enabled.load(std::memory_order_acquire);
  if (enabled != _appliedEnabled) {
    for (const auto& processor : _processors) {
      processor->SetEnabled(enabled);
    }
    _appliedEnabled = enabled;
  }
  if (!enabled) return;

  const size_t channelCount =
      std::min(audioBuffer.channels, _processors.size());
  for (size_t channel = 0; channel < channelCount; ++channel) {
    _processors[channel]->Process([audioBuffer rawBufferForChannel:channel],
                                  audioBuffer.frames);
  }
}

- (void)audioProcessingRelease {
  _processors.clear();
  _appliedEnabled = false;
}

@end

@implementation OpenSpeakAudioProcessingBridge {
  FlutterMethodChannel* _channel;
  OpenSpeakCaptureProcessor* _processor;
}

+ (void)registerWithBinaryMessenger:(id<FlutterBinaryMessenger>)messenger {
  static OpenSpeakAudioProcessingBridge* bridge;
  if (bridge == nil) {
    bridge = [[OpenSpeakAudioProcessingBridge alloc]
        initWithBinaryMessenger:messenger];
  }
}

- (instancetype)initWithBinaryMessenger:
    (id<FlutterBinaryMessenger>)messenger {
  self = [super init];
  if (self) {
    _processor = [[OpenSpeakCaptureProcessor alloc] init];
    [[AudioManager sharedInstance].capturePostProcessingAdapter
        addProcessing:_processor];

    _channel = [FlutterMethodChannel
        methodChannelWithName:@"openspeak/audio_processing"
              binaryMessenger:messenger];
    __weak OpenSpeakCaptureProcessor* processor = _processor;
    [_channel setMethodCallHandler:^(FlutterMethodCall* call,
                                     FlutterResult result) {
      if (![call.method isEqualToString:@"setNoiseSuppressionEnabled"]) {
        result(FlutterMethodNotImplemented);
        return;
      }
      if (![call.arguments isKindOfClass:[NSNumber class]]) {
        result([FlutterError errorWithCode:@"invalid_argument"
                                   message:@"Expected a boolean argument"
                                   details:nil]);
        return;
      }
      [processor setEnabled:[(NSNumber*)call.arguments boolValue]];
      result(nil);
    }];
  }
  return self;
}

@end
