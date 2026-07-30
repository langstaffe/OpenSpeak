import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'openspeak_api.dart';

class ScreenShareQuality {
  const ScreenShareQuality(this.resolution, this.fps);

  final String resolution;
  final int fps;

  String get resolutionLabel => switch (resolution) {
    '720p' => '720p',
    '1080p' => '1080p',
    'source' => 'Source',
    _ => resolution,
  };

  String get label => '$resolutionLabel · $fps FPS';
}

const voiceScreenSharePermission = 'voice.screen_share';
const screenShareResolutionPermissions = <String, String>{
  '720p': 'voice.screen_share.resolution.720p',
  '1080p': 'voice.screen_share.resolution.1080p',
  'source': 'voice.screen_share.resolution.source',
};
const screenShareFPSPermissions = <int, String>{
  15: 'voice.screen_share.fps.15',
  30: 'voice.screen_share.fps.30',
  60: 'voice.screen_share.fps.60',
};

List<ScreenShareQuality> allowedScreenShareQualities(Set<String> permissions) =>
    screenShareQualities
        .where(
          (quality) =>
              permissions.contains(voiceScreenSharePermission) &&
              permissions.contains(
                screenShareResolutionPermissions[quality.resolution],
              ) &&
              permissions.contains(screenShareFPSPermissions[quality.fps]),
        )
        .toList();

const screenShareQualities = <ScreenShareQuality>[
  ScreenShareQuality('720p', 15),
  ScreenShareQuality('720p', 30),
  ScreenShareQuality('720p', 60),
  ScreenShareQuality('1080p', 15),
  ScreenShareQuality('1080p', 30),
  ScreenShareQuality('1080p', 60),
  ScreenShareQuality('source', 15),
  ScreenShareQuality('source', 30),
  ScreenShareQuality('source', 60),
];

lk.VideoParameters screenShareVideoParameters(
  ScreenShareQuality quality, {
  int maxBitrateMbps = 0,
}) {
  final dimensions = switch (quality.resolution) {
    '720p' => lk.VideoDimensionsPresets.h720_169,
    '1080p' => lk.VideoDimensionsPresets.h1080_169,
    // ponytail: LiveKit 2.8.1 在采集前不暴露桌面源尺寸，因此第一版用 4K
    // 作为 Source 上限，不为此增加额外 UI。
    'source' => lk.VideoDimensionsPresets.h2160_169,
    _ => throw ArgumentError.value(
      quality.resolution,
      'quality.resolution',
      'unsupported screen-share resolution',
    ),
  };
  final bitrateMbps = maxBitrateMbps > 0
      ? maxBitrateMbps
      : ScreenShareBitrateLimits.defaults.bitrateMbps(
          quality.resolution,
          quality.fps,
        );
  return lk.VideoParameters(
    dimensions: dimensions,
    encoding: lk.VideoEncoding(
      maxBitrate: bitrateMbps * 1000000,
      maxFramerate: quality.fps,
      bitratePriority: lk.Priority.high,
    ),
  );
}

lk.VideoPublishOptions screenShareVideoPublishOptions(
  lk.VideoEncoding? encoding,
  TargetPlatform platform, {
  bool isWeb = kIsWeb,
}) {
  if (isWeb ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows) {
    return lk.VideoPublishOptions(
      videoCodec: 'h264',
      screenShareEncoding: encoding,
      simulcast: false,
      degradationPreference: !isWeb && platform == TargetPlatform.macOS
          ? lk.DegradationPreference.maintainFramerate
          : null,
      backupVideoCodec: const lk.BackupVideoCodec(enabled: false),
    );
  }
  return lk.VideoPublishOptions(
    screenShareEncoding: encoding,
    simulcast: false,
  );
}

bool supportsH264VideoEncoding(Iterable<rtc.RTCRtpCodecCapability>? codecs) =>
    codecs?.any((codec) => codec.mimeType.toLowerCase() == 'video/h264') ==
    true;

double? rtpBitrateBitsPerSecond({
  required num? bytes,
  required num? previousBytes,
  required num? timestamp,
  required num? previousTimestamp,
  required bool timestampInMicroseconds,
}) {
  if (bytes == null ||
      previousBytes == null ||
      timestamp == null ||
      previousTimestamp == null ||
      bytes < previousBytes ||
      timestamp <= previousTimestamp) {
    return null;
  }
  final timestampUnitsPerSecond = timestampInMicroseconds ? 1000000 : 1000;
  return (bytes - previousBytes) *
      8 *
      timestampUnitsPerSecond /
      (timestamp - previousTimestamp);
}

double screenShareScaleDownBy({
  required num sourceWidth,
  required num sourceHeight,
  required lk.VideoDimensions target,
}) {
  if (!sourceWidth.isFinite ||
      !sourceHeight.isFinite ||
      sourceWidth <= 0 ||
      sourceHeight <= 0) {
    return 1;
  }
  return math
      .max(
        1,
        math.max(sourceWidth / target.width, sourceHeight / target.height),
      )
      .toDouble();
}

rtc.StatsReport? selectedCandidatePairReport(
  Iterable<rtc.StatsReport> reports,
) {
  String? selectedPairId;
  for (final report in reports) {
    if (report.type != 'transport') continue;
    final value = report.values['selectedCandidatePairId'];
    if (value is String && value.isNotEmpty) selectedPairId = value;
  }
  rtc.StatsReport? legacySelectedPair;
  for (final report in reports) {
    if (report.type != 'candidate-pair') continue;
    if (selectedPairId != null && report.id == selectedPairId) return report;
    if (legacySelectedPair == null && report.values['selected'] == true) {
      legacySelectedPair = report;
    }
  }
  return legacySelectedPair;
}

num? selectedCandidatePairValue(Iterable<rtc.StatsReport> reports, String key) {
  final value = selectedCandidatePairReport(reports)?.values[key];
  return value is num ? value : null;
}

num? selectedCandidatePairRoundTripTime(Iterable<rtc.StatsReport> reports) =>
    selectedCandidatePairValue(reports, 'currentRoundTripTime');

double? screenShareAspectRatioForDimensions(num? width, num? height) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return width / height;
}

class VoiceScreenShare {
  const VoiceScreenShare({
    required this.track,
    required this.userId,
    required this.displayName,
    required this.aspectRatio,
  });

  final lk.VideoTrack track;
  final String userId;
  final String displayName;
  final double aspectRatio;
}
