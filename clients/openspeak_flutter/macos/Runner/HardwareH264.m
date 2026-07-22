#import <VideoToolbox/VideoToolbox.h>

static OSStatus OpenSpeakVTCompressionSessionCreate(
    CFAllocatorRef allocator,
    int32_t width,
    int32_t height,
    CMVideoCodecType codecType,
    CFDictionaryRef encoderSpecification,
    CFDictionaryRef sourceImageBufferAttributes,
    CFAllocatorRef compressedDataAllocator,
    VTCompressionOutputCallback outputCallback,
    void *outputCallbackRefCon,
    VTCompressionSessionRef *compressionSessionOut) {
  CFMutableDictionaryRef requiredHardwareSpecification = NULL;
  if (codecType == kCMVideoCodecType_H264) {
    if (encoderSpecification != NULL) {
      requiredHardwareSpecification = CFDictionaryCreateMutableCopy(
          kCFAllocatorDefault, 0, encoderSpecification);
    } else {
      requiredHardwareSpecification = CFDictionaryCreateMutable(
          kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
    }
    if (requiredHardwareSpecification == NULL) return kVTAllocationFailedErr;
    CFDictionarySetValue(
        requiredHardwareSpecification,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder,
        kCFBooleanTrue);
    encoderSpecification = requiredHardwareSpecification;
  }

  OSStatus status = VTCompressionSessionCreate(
      allocator, width, height, codecType, encoderSpecification,
      sourceImageBufferAttributes, compressedDataAllocator, outputCallback,
      outputCallbackRefCon, compressionSessionOut);
  if (requiredHardwareSpecification != NULL) {
    CFRelease(requiredHardwareSpecification);
  }
  return status;
}

__attribute__((used)) static struct {
  const void *replacement;
  const void *replacee;
} OpenSpeakHardwareH264Interpose
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)OpenSpeakVTCompressionSessionCreate,
        (const void *)VTCompressionSessionCreate,
};
