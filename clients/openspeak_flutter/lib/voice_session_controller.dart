import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'client_log.dart';
import 'livekit_room_factory.dart';
import 'microphone_activation.dart';
import 'openspeak_api.dart';

const _minimumVoiceAudioRms = 0.0008;
const _minimumWindowsVoiceAudioRms = 0.0001;
const _noiseFloorMultiplier = 1.8;
const _windowsWebRtcLevelIdleDelay = Duration(milliseconds: 120);
const _microphoneThresholdReleaseDelay = Duration(milliseconds: 250);

bool audioEnergyIndicatesActivity(
  num energyDelta,
  num durationDelta, {
  double noiseFloorRms = 0,
}) {
  if (energyDelta <= 0 || durationDelta <= 0) return false;
  final rms = math.sqrt(energyDelta / durationDelta);
  final threshold = math.max(
    _minimumVoiceAudioRms,
    noiseFloorRms * _noiseFloorMultiplier,
  );
  return rms >= threshold;
}

double effectiveParticipantOutputVolume(
  double outputVolume,
  double participantVolume,
) => (outputVolume.clamp(0.0, 1.0) * participantVolume.clamp(0.0, 2.0))
    .clamp(0.0, 2.0)
    .toDouble();

lk.AudioPublishOptions voiceAudioPublishOptions(
  int bitrateKbps, {
  bool isWeb = kIsWeb,
}) => lk.AudioPublishOptions(
  encoding: lk.AudioEncoding(maxBitrate: bitrateKbps * 1000),
  dtx: !isWeb,
  red: true,
);

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
  if (!isWeb &&
      (platform == TargetPlatform.macOS ||
          platform == TargetPlatform.windows)) {
    return lk.VideoPublishOptions(
      videoCodec: 'h264',
      screenShareEncoding: encoding,
      simulcast: false,
      degradationPreference: platform == TargetPlatform.macOS
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

double? counterAverageDelta({
  required num? total,
  required num? previousTotal,
  required num? count,
  required num? previousCount,
}) {
  if (total == null ||
      previousTotal == null ||
      count == null ||
      previousCount == null ||
      total < previousTotal ||
      count <= previousCount) {
    return null;
  }
  return (total - previousTotal) / (count - previousCount);
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

num? selectedCandidatePairValue(Iterable<rtc.StatsReport> reports, String key) {
  String? selectedPairId;
  for (final report in reports) {
    if (report.type != 'transport') continue;
    final value = report.values['selectedCandidatePairId'];
    if (value is String && value.isNotEmpty) selectedPairId = value;
  }
  for (final report in reports) {
    if (report.type != 'candidate-pair' ||
        (report.id != selectedPairId && report.values['selected'] != true)) {
      continue;
    }
    final value = report.values[key];
    if (value is num) return value;
  }
  return null;
}

num? selectedCandidatePairRoundTripTime(Iterable<rtc.StatsReport> reports) =>
    selectedCandidatePairValue(reports, 'currentRoundTripTime');

double? screenShareAspectRatioForDimensions(num? width, num? height) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return width / height;
}

Future<bool> _limitWindowsScreenShareResolution(
  lk.LocalVideoTrack track,
  lk.VideoDimensions target,
  bool Function() isCurrent,
) async {
  try {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!isCurrent()) return false;
      final sender = track.sender;
      if (sender != null) {
        for (final stats in await track.getSenderStats()) {
          if (!isCurrent()) return false;
          final sourceWidth = stats.frameWidth ?? 0;
          final sourceHeight = stats.frameHeight ?? 0;
          if (sourceWidth <= 0 || sourceHeight <= 0) continue;

          final parameters = sender.parameters;
          final encodings = parameters.encodings;
          if (encodings == null || encodings.isEmpty) break;
          final scale = screenShareScaleDownBy(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            target: target,
          );
          for (final encoding in encodings) {
            if (encoding.active) encoding.scaleResolutionDownBy = scale;
          }
          parameters.degradationPreference =
              rtc.RTCDegradationPreference.MAINTAIN_FRAMERATE;
          if (!isCurrent()) return false;
          final applied = await sender.setParameters(parameters);
          ClientLog.write(
            'voice.screen',
            'windows sender limit applied=$applied '
                'source=${sourceWidth.toInt()}x${sourceHeight.toInt()} '
                'target=${target.width}x${target.height} '
                'scale=${scale.toStringAsFixed(3)} '
                'fps=${stats.framesPerSecond ?? 0} '
                'encoder=${stats.encoderImplementation ?? 'unknown'}',
          );
          return applied;
        }
      }
      if (attempt < 19) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return false;
  } catch (error, stackTrace) {
    if (isCurrent()) {
      ClientLog.error('voice.screen.windows_limit', error, stackTrace);
    }
    return false;
  }
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

class _OpenSpeakAudioCaptureOptions extends lk.AudioCaptureOptions {
  const _OpenSpeakAudioCaptureOptions({
    required bool noiseSuppressionEnabled,
    super.deviceId,
  }) : super(
         echoCancellation: true,
         autoGainControl: true,
         noiseSuppression: noiseSuppressionEnabled,
         highPassFilter: noiseSuppressionEnabled,
         typingNoiseDetection: noiseSuppressionEnabled,
         voiceIsolation: noiseSuppressionEnabled,
         stopAudioCaptureOnMute: false,
       );

  @override
  Map<String, dynamic> toMediaConstraintsMap() {
    final constraints = super.toMediaConstraintsMap();
    if (kIsWeb && deviceId?.isNotEmpty == true) {
      constraints.addAll({
        'echoCancellation': echoCancellation,
        'autoGainControl': autoGainControl,
        'noiseSuppression': noiseSuppression,
        'voiceIsolation': voiceIsolation,
      });
    }
    return constraints;
  }
}

lk.AudioCaptureOptions voiceAudioCaptureOptions({
  required bool noiseSuppressionEnabled,
  String? deviceId,
}) {
  return _OpenSpeakAudioCaptureOptions(
    deviceId: deviceId,
    noiseSuppressionEnabled: noiseSuppressionEnabled,
  );
}

bool microphoneActivationGateOpen({
  required MicrophoneActivationMode mode,
  required bool pushToTalkPressed,
  required bool thresholdOpen,
}) => switch (mode) {
  MicrophoneActivationMode.pushToTalk => pushToTalkPressed,
  MicrophoneActivationMode.continuous => true,
  MicrophoneActivationMode.voiceThreshold => thresholdOpen,
};

bool microphoneAudioShouldTransmit({
  required bool activationOpen,
  required bool hasRemoteParticipants,
}) => activationOpen && hasRemoteParticipants;

bool microphoneSenderRoutingAllowed({
  required bool reconnecting,
  required bool roomConnected,
  bool roomConnecting = false,
}) => roomConnected && !reconnecting && !roomConnecting;

bool persistentRoomChannelSwitchAllowed({
  required bool persistentRoom,
  required bool connected,
}) => persistentRoom && connected;

bool microphoneCaptureRestartShouldDefer({
  required bool roomConnecting,
  required bool restartRequested,
}) => roomConnecting && restartRequested;

Duration liveKitReconnectDelay(int attempts) => const <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
  Duration(seconds: 30),
][attempts.clamp(0, 5).toInt()];

bool voiceRoomEventShouldFinalizeSession({required bool connecting}) =>
    !connecting;

Future<void> closeVoiceRoom({
  required Future<void> Function() sendLeave,
  required Future<void> Function() dispose,
  Future<void>? routingDone,
}) async {
  try {
    await sendLeave();
  } catch (error, stackTrace) {
    ClientLog.error('voice.room_leave', error, stackTrace);
  }
  await dispose();
  if (routingDone != null) await routingDone;
}

Future<void> switchVoiceChannelWithReconnectFallback({
  required Future<void> Function() switchWithoutReconnect,
  required Future<void> Function(Object, StackTrace) reconnect,
}) async {
  try {
    await switchWithoutReconnect();
  } catch (error, stackTrace) {
    await reconnect(error, stackTrace);
  }
}

bool microphoneCaptureRestartShouldRun({
  required bool restartPending,
  required bool shouldTransmit,
}) => restartPending && shouldTransmit;

bool microphoneCaptureRestartShouldDetachSender(
  TargetPlatform platform, {
  bool isWeb = false,
}) => !isWeb && platform == TargetPlatform.windows;

bool microphoneSenderReplacementShouldRun({
  required bool force,
  required bool alreadyAttached,
}) => force || !alreadyAttached;

bool microphoneSenderShouldStayAttached({
  required bool isWeb,
  required bool shouldTransmit,
}) => isWeb || shouldTransmit;

bool microphoneRmsIndicatesActivity(double rms) => rms >= _minimumVoiceAudioRms;

bool voiceStateSyncShouldRetry(OpenSpeakException error) =>
    error.code == 'websocket_required' ||
    error.message.contains('open a server WebSocket connection');

bool voiceStateSyncShouldRejoinChannel(OpenSpeakException error) =>
    error.code == 'current_channel_required' ||
    error.message.contains('enter the channel before updating its voice state');

bool voiceE2EEConfigurationValid({
  required VoiceToken token,
  required Uint8List? key,
  required String deviceId,
  required String epochId,
}) {
  final configured = key != null || deviceId.isNotEmpty || epochId.isNotEmpty;
  if (!token.e2eeRequired) return !configured;
  return key?.length == 32 &&
      deviceId.isNotEmpty &&
      epochId.isNotEmpty &&
      (token.roomScope != 'server' || token.e2eeParticipantKeys) &&
      (token.e2eeKeyIndex == 0 || token.e2eeKeyIndex == 1) &&
      token.e2eeEpochId == epochId;
}

bool voiceE2EEUsesParticipantKeys(VoiceToken token) =>
    token.e2eeRequired &&
    token.roomScope == 'server' &&
    token.e2eeParticipantKeys;

bool voiceTokenRequiresRoomReconnect(
  VoiceToken? currentToken,
  VoiceToken refreshedToken,
) =>
    currentToken == null ||
    currentToken.room != refreshedToken.room ||
    currentToken.roomScope != refreshedToken.roomScope ||
    currentToken.e2eeRequired != refreshedToken.e2eeRequired ||
    currentToken.e2eeParticipantKeys != refreshedToken.e2eeParticipantKeys;

bool realtimeReconnectRequiresVoiceRestart({
  required bool e2eeServer,
  required VoiceToken? currentToken,
  required String currentMediaEpochId,
  int currentMediaKeyIndex = 0,
  bool mediaKeySlots = false,
  VoiceToken? refreshedToken,
}) =>
    e2eeServer &&
    (currentToken == null ||
        (refreshedToken != null &&
            voiceTokenRequiresRoomReconnect(currentToken, refreshedToken)) ||
        currentToken.e2eeEpochId != currentMediaEpochId ||
        currentToken.e2eeKeyIndex != currentMediaKeyIndex ||
        currentToken.mediaKeySlots != mediaKeySlots);

List<({String participantId, int keyIndex})>
voiceE2EEParticipantKeyInstallPlan({
  required Iterable<String> participantIds,
  required String localUserId,
  required int keyIndex,
  required bool mirror,
}) {
  final identities = <String>{
    for (final participantId in participantIds)
      if (participantId.isNotEmpty) participantId,
    if (localUserId.isNotEmpty) localUserId,
  };
  return [
    for (final participantId in identities) ...[
      if (mirror) (participantId: participantId, keyIndex: 1 - keyIndex),
      (participantId: participantId, keyIndex: keyIndex),
    ],
  ];
}

rtc.KeyProviderOptions voiceE2EEKeyProviderOptions({bool sharedKey = true}) =>
    rtc.KeyProviderOptions(
      sharedKey: sharedKey,
      ratchetSalt: Uint8List.fromList(lk.defaultRatchetSalt.codeUnits),
      ratchetWindowSize: lk.defaultRatchetWindowSize,
      uncryptedMagicBytes: Uint8List.fromList(lk.defaultMagicBytes.codeUnits),
      failureTolerance: lk.defaultFailureTolerance,
      keyRingSize: lk.defaultKeyRingSize,
      discardFrameWhenCryptorNotReady: true,
    );

String voiceJoinFailureStatus({
  required bool liveKitConnected,
  required bool syncingVoiceState,
  String? failedUrl,
}) {
  if (!liveKitConnected) {
    return failedUrl == null ? '未连接' : 'LiveKit 连接失败: $failedUrl';
  }
  return syncingVoiceState ? '语音状态同步失败' : '语音初始化失败';
}

class WindowsMicrophoneActivityDetector {
  double? _noiseFloorRms;
  var _activeFrames = 0;

  double get noiseFloorRms => _noiseFloorRms ?? 0;

  bool update(double rms) {
    final sample = rms.clamp(0.0, 1.0).toDouble();
    final previousFloor = _noiseFloorRms;
    if (previousFloor == null) {
      _noiseFloorRms = sample;
      // Do not mistake the device's steady idle floor for speech on startup,
      // but let an unmistakably loud first packet light the ring immediately.
      return sample >= 0.003;
    }

    final threshold = math.max(
      _minimumWindowsVoiceAudioRms,
      previousFloor * _noiseFloorMultiplier,
    );
    final active = sample >= threshold;
    if (active) {
      _activeFrames += 1;
      // A suddenly louder, steady device floor must not leave the ring on
      // forever. Start following it only after roughly half a second.
      if (_activeFrames >= 25) {
        _noiseFloorRms = previousFloor * 0.95 + sample * 0.05;
      }
    } else {
      _activeFrames = 0;
      final follow = sample < previousFloor ? 0.2 : 0.02;
      _noiseFloorRms = previousFloor * (1 - follow) + sample * follow;
    }
    return active;
  }

  void reset() {
    _noiseFloorRms = null;
    _activeFrames = 0;
  }
}

bool microphonePcmMonitorSupported(
  TargetPlatform platform, {
  bool isWeb = false,
}) =>
    isWeb ||
    platform == TargetPlatform.android ||
    platform == TargetPlatform.iOS ||
    platform == TargetPlatform.macOS;

bool windowsMicrophoneLevelUsesWebRtc({
  required bool fastConnecting,
  required bool transmitting,
}) => fastConnecting || transmitting;

bool voiceShouldAutoSubscribe({
  required bool listenOff,
  bool e2eeRequired = false,
  bool persistentRoom = false,
}) => !listenOff && !e2eeRequired && !persistentRoom;

bool webMicrophoneCaptureCanFallBackToListenOnly(
  Object error, {
  required bool isWeb,
}) => isWeb && error.toString().contains('NotFoundError');

bool webLiveKitJoinResponseCanRetry(Object error, {required bool isWeb}) =>
    isWeb &&
    error.toString().contains('Timed out waiting for SignalJoinResponseEvent');

bool voiceShouldKeepMicrophoneTrack({
  required bool canPublish,
  required bool listenOff,
  required bool microphoneUnavailable,
}) => canPublish && !listenOff && !microphoneUnavailable;

bool voiceParticipantInCurrentChannel({
  required bool persistentRoom,
  required Set<String> channelMemberUserIds,
  required String userId,
}) => !persistentRoom || channelMemberUserIds.contains(userId);

bool voiceTrackEncryptionAccepted({
  required bool e2eeRequired,
  required lk.EncryptionType encryptionType,
}) => !e2eeRequired || encryptionType == lk.EncryptionType.kGcm;

num packetCounterDelta(num current, num? previous) =>
    previous == null || current < previous ? 0 : current - previous;

Set<String> withLocalSpeakingState(
  Iterable<String> speakingUserIds, {
  required String? localUserId,
  required bool speaking,
}) {
  final next = speakingUserIds.toSet();
  if (localUserId == null || localUserId.isEmpty) return next;
  speaking ? next.add(localUserId) : next.remove(localUserId);
  return next;
}

class _AudioEnergySample {
  const _AudioEnergySample({
    required this.energy,
    required this.duration,
    required this.noiseFloorRms,
  });

  final num? energy;
  final num? duration;
  final double noiseFloorRms;
}

class VoiceSessionSnapshot {
  const VoiceSessionSnapshot({
    required this.connecting,
    required this.connected,
    required this.reconnecting,
    required this.muted,
    required this.listenOff,
    required this.speaking,
    required this.status,
    required this.remoteParticipants,
    required this.remoteAudioTracks,
    required this.liveKitParticipantUserIds,
    required this.liveKitSpeakingUserIds,
    required this.remoteAudioBitrate,
    required this.remoteAudioBytesReceived,
    this.upstreamPacketLoss,
    this.downstreamPacketLoss,
    this.latencyMs,
    this.latencyJitterMs,
    this.voiceToken,
    this.voiceState,
  });

  factory VoiceSessionSnapshot.initial() {
    return const VoiceSessionSnapshot(
      connecting: false,
      connected: false,
      reconnecting: false,
      muted: false,
      listenOff: false,
      speaking: false,
      status: '未连接',
      remoteParticipants: 0,
      remoteAudioTracks: 0,
      liveKitParticipantUserIds: {},
      liveKitSpeakingUserIds: {},
      remoteAudioBitrate: 0,
      remoteAudioBytesReceived: 0,
      upstreamPacketLoss: null,
      downstreamPacketLoss: null,
      latencyMs: null,
      latencyJitterMs: null,
    );
  }

  final bool connecting;
  final bool connected;
  final bool reconnecting;
  final bool muted;
  final bool listenOff;
  final bool speaking;
  final String status;
  final int remoteParticipants;
  final int remoteAudioTracks;
  final Set<String> liveKitParticipantUserIds;
  final Set<String> liveKitSpeakingUserIds;
  final num remoteAudioBitrate;
  final int remoteAudioBytesReceived;
  final double? upstreamPacketLoss;
  final double? downstreamPacketLoss;
  final double? latencyMs;
  final double? latencyJitterMs;
  final VoiceToken? voiceToken;
  final VoiceState? voiceState;

  VoiceSessionSnapshot copyWith({
    bool? connecting,
    bool? connected,
    bool? reconnecting,
    bool? muted,
    bool? listenOff,
    bool? speaking,
    String? status,
    int? remoteParticipants,
    int? remoteAudioTracks,
    Set<String>? liveKitParticipantUserIds,
    Set<String>? liveKitSpeakingUserIds,
    num? remoteAudioBitrate,
    int? remoteAudioBytesReceived,
    double? upstreamPacketLoss,
    double? downstreamPacketLoss,
    double? latencyMs,
    double? latencyJitterMs,
    VoiceToken? voiceToken,
    VoiceState? voiceState,
    bool clearVoiceToken = false,
    bool clearVoiceState = false,
    bool clearMediaNetworkStats = false,
    bool clearLatencyStats = false,
  }) {
    return VoiceSessionSnapshot(
      connecting: connecting ?? this.connecting,
      connected: connected ?? this.connected,
      reconnecting: reconnecting ?? this.reconnecting,
      muted: muted ?? this.muted,
      listenOff: listenOff ?? this.listenOff,
      speaking: speaking ?? this.speaking,
      status: status ?? this.status,
      remoteParticipants: remoteParticipants ?? this.remoteParticipants,
      remoteAudioTracks: remoteAudioTracks ?? this.remoteAudioTracks,
      liveKitParticipantUserIds:
          liveKitParticipantUserIds ?? this.liveKitParticipantUserIds,
      liveKitSpeakingUserIds:
          liveKitSpeakingUserIds ?? this.liveKitSpeakingUserIds,
      remoteAudioBitrate: remoteAudioBitrate ?? this.remoteAudioBitrate,
      remoteAudioBytesReceived:
          remoteAudioBytesReceived ?? this.remoteAudioBytesReceived,
      upstreamPacketLoss: clearMediaNetworkStats
          ? null
          : (upstreamPacketLoss ?? this.upstreamPacketLoss),
      downstreamPacketLoss: clearMediaNetworkStats
          ? null
          : (downstreamPacketLoss ?? this.downstreamPacketLoss),
      latencyMs: clearLatencyStats ? null : (latencyMs ?? this.latencyMs),
      latencyJitterMs: clearLatencyStats
          ? null
          : (latencyJitterMs ?? this.latencyJitterMs),
      voiceToken: clearVoiceToken ? null : (voiceToken ?? this.voiceToken),
      voiceState: clearVoiceState ? null : (voiceState ?? this.voiceState),
    );
  }
}

class VoiceSessionController extends ChangeNotifier {
  static const _liveKitTimeouts = lk.Timeouts(
    connection: Duration(seconds: 30),
    debounce: Duration(milliseconds: 20),
    publish: Duration(seconds: 30),
    subscribe: Duration(seconds: 30),
    peerConnection: Duration(seconds: 30),
    iceRestart: Duration(seconds: 15),
  );

  VoiceSessionSnapshot snapshot = VoiceSessionSnapshot.initial();

  lk.Room? _room;
  lk.Room? _connectingRoom;
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  lk.Room? _screenRoom;
  lk.EventsListener<lk.RoomEvent>? _screenRoomListener;
  Timer? _screenStatsTimer;
  ScreenShareToken? _screenToken;
  String? _expectedScreenPublisherUserId;
  int _screenRoomGeneration = 0;
  int _screenViewerRequestGeneration = 0;
  Future<void> _screenShareTransitionTail = Future<void>.value();
  bool _disposingScreenRoom = false;
  bool _screenStatsPollInFlight = false;
  bool _screenStatsFailureLogged = false;
  double? _screenShareAspectRatio;
  num? _screenStatsPreviousPackets;
  num? _screenStatsPreviousLost;
  num? _screenStatsPreviousBytes;
  num? _screenStatsPreviousTimestamp;
  num? _screenStatsPreviousQpSum;
  num? _screenStatsPreviousFramesEncoded;
  final Map<String, lk.EventsListener<lk.ParticipantEvent>>
  _remoteParticipantListeners = {};
  OpenSpeakApi? _api;
  String? _authToken;
  String? _serverId;
  String _localUserId = '';
  String? _channelId;
  Set<String> _channelMemberUserIds = const {};
  Set<String> _authorizedScreenSharingUserIds = const {};
  ScreenShareQuality? _screenShareQuality;
  bool _persistentChannelSwitchIsolated = false;
  Uint8List? _e2eeKey;
  Uint8List? _retiringE2EEKey;
  bool _e2eeParticipantKeys = false;
  String _e2eeDeviceId = '';
  String _e2eeEpochId = '';
  int _activeE2EEKeyIndex = 0;
  int? _stagedE2EEKeyIndex;
  bool _e2eeMediaActive = true;
  Timer? _e2eeOldKeyRetireTimer;
  String? _audioInputDeviceId;
  String? _audioOutputDeviceId;
  bool _webMicrophoneUnavailable = false;
  bool _noiseSuppressionEnabled = true;
  MicrophoneActivationMode _microphoneActivationMode =
      MicrophoneActivationMode.continuous;
  double _microphoneThreshold = 0.4;
  bool _pushToTalkPressed = false;
  bool _thresholdGateOpen = false;
  DateTime? _thresholdReleaseAt;
  Timer? _thresholdGateReleaseTimer;
  bool _microphoneGateOpen = false;
  double _outputVolume = 1.0;
  final Map<String, double> _participantOutputVolumes = {};
  Timer? _speakingSyncTimer;
  Timer? _speakingPollTimer;
  Timer? _serverLatencyTimer;
  Timer? _audioStatsTimer;
  Timer? _liveKitReconnectTimer;
  bool _intentionalLeave = false;
  bool _reconnectInFlight = false;
  int _liveKitReconnectAttempts = 0;
  int _sessionGeneration = 0;
  bool _disposed = false;
  bool _latencyMeasurementInFlight = false;
  bool _audioStatsPollInFlight = false;
  bool _audioActivityPollInFlight = false;
  Object? _microphonePreviewOwner;
  Future<void> Function()? _releaseMicrophonePreview;
  OpenSpeakApi? _latencyApi;
  double? _previousLatencyMs;
  double _latencyJitterMs = 0;
  final Map<String, num> _receiverPacketsReceived = {};
  final Map<String, num> _receiverPacketsLost = {};
  final Map<String, num> _receiverJitterBufferDelay = {};
  final Map<String, num> _receiverJitterBufferEmittedCount = {};
  final Map<String, num> _senderPacketsSent = {};
  final Map<String, num> _senderPacketsLost = {};
  final Map<String, _AudioEnergySample> _audioEnergySamples = {};
  Future<void> _microphoneRoutingTail = Future<void>.value();
  Future<void> _mediaRoutingTail = Future<void>.value();
  int _microphoneRoutingRevision = 0;
  lk.LocalAudioTrack? _microphoneCaptureTrack;
  rtc.MediaStreamTrack? _webMicrophoneSenderTrack;
  bool _microphoneCaptureRestartPending = false;
  lk.LocalAudioTrack? _microphoneMonitorTrack;
  bool? _windowsMonitorUsesWebRtc;
  Timer? _windowsMicrophoneLevelIdleTimer;
  lk.CancelListenFunc? _removeMicrophoneMonitor;
  final WindowsMicrophoneLevelMonitor _windowsMicrophoneLevelMonitor =
      WindowsMicrophoneLevelMonitor();
  final WindowsMicrophoneActivityDetector _windowsActivityDetector =
      WindowsMicrophoneActivityDetector();
  bool _localAudioActive = false;
  final ValueNotifier<double> microphoneInputLevel = ValueNotifier(0);
  final ValueNotifier<bool> microphoneInputActive = ValueNotifier(false);

  bool get isJoined =>
      snapshot.connected || snapshot.connecting || snapshot.voiceState != null;

  int beginJoinRequest() => ++_sessionGeneration;

  bool isJoinRequestCurrent(int request) => _isActiveSessionGeneration(request);

  bool get needsVoiceMicrophoneCapture => _microphoneCaptureTrack != null;
  bool get microphoneUnavailable => _webMicrophoneUnavailable;

  bool get usesPersistentRoom =>
      snapshot.voiceToken?.roomScope == 'server' && _room != null;

  bool get canSwitchPersistentChannel => persistentRoomChannelSwitchAllowed(
    persistentRoom: usesPersistentRoom,
    connected: snapshot.connected,
  );

  String? get currentChannelId => _channelId;

  bool get isScreenSharing =>
      _screenRoom?.localParticipant?.isScreenShareEnabled() == true;

  String? get _remoteScreenSharingUserId {
    final room = _screenRoom;
    if (room == null) return null;
    for (final participant in room.remoteParticipants.values) {
      if (participant.identity != _expectedScreenPublisherUserId ||
          !_authorizedScreenSharingUserIds.contains(participant.identity)) {
        continue;
      }
      for (final publication in participant.videoTrackPublications) {
        if (publication.source == lk.TrackSource.screenShareVideo &&
            !publication.muted &&
            voiceTrackEncryptionAccepted(
              e2eeRequired: snapshot.voiceToken?.e2eeRequired == true,
              encryptionType: publication.encryptionType,
            )) {
          return participant.identity;
        }
      }
    }
    return null;
  }

  String? get screenSharingUserId {
    final remoteUserId = _remoteScreenSharingUserId;
    if (remoteUserId != null) return remoteUserId;
    if (!isScreenSharing) return null;
    return _screenRoom?.localParticipant?.identity;
  }

  VoiceScreenShare? get activeScreenShare {
    final room = _screenRoom;
    if (room == null) return null;
    for (final participant in room.remoteParticipants.values) {
      if (participant.identity != _expectedScreenPublisherUserId ||
          !_authorizedScreenSharingUserIds.contains(participant.identity)) {
        continue;
      }
      for (final publication in participant.videoTrackPublications) {
        if (publication.source != lk.TrackSource.screenShareVideo ||
            !publication.subscribed ||
            publication.muted) {
          continue;
        }
        final track = publication.track;
        if (track == null) continue;
        final dimensions = publication.dimensions;
        return VoiceScreenShare(
          track: track,
          userId: participant.identity,
          displayName: participant.name,
          aspectRatio:
              _screenShareAspectRatio ??
              screenShareAspectRatioForDimensions(
                dimensions?.width,
                dimensions?.height,
              ) ??
              16 / 9,
        );
      }
    }
    return null;
  }

  Future<void> startScreenShare({
    required String sourceId,
    required ScreenShareQuality quality,
  }) => _enqueueScreenShareTransition(
    () => _startScreenShare(sourceId: sourceId, quality: quality),
  );

  Future<void> _startScreenShare({
    required String sourceId,
    required ScreenShareQuality quality,
  }) async {
    final api = _api;
    final authToken = _authToken;
    final channelId = _channelId;
    if (_room == null ||
        api == null ||
        authToken == null ||
        channelId == null ||
        !snapshot.connected ||
        _persistentChannelSwitchIsolated) {
      throw OpenSpeakException('请先进入语音频道');
    }
    if (snapshot.voiceToken?.canShareScreen != true) {
      throw OpenSpeakException('没有屏幕共享权限');
    }
    if (snapshot.voiceToken?.e2eeRequired == true && !_e2eeMediaActive) {
      throw OpenSpeakException('正在等待语音媒体密钥切换');
    }
    if (isScreenSharing) return;
    if (_remoteScreenSharingUserId != null) {
      throw OpenSpeakException('当前频道有人正在分享屏幕');
    }
    final sessionGeneration = _sessionGeneration;
    final token = await api.getScreenShareToken(
      authToken,
      channelId,
      publish: true,
      resolution: quality.resolution,
      fps: quality.fps,
      deviceId: _e2eeDeviceId,
      e2eeEpochId: _e2eeEpochId,
    );
    if (!_isActiveSessionGeneration(sessionGeneration) ||
        channelId != _channelId) {
      return;
    }
    if (token.url.isEmpty || token.token.isEmpty || !token.canPublish) {
      throw OpenSpeakException('屏幕共享节点没有返回有效的发布凭据');
    }
    final room = await _connectScreenRoom(
      token,
      expectedPublisherUserId: token.publisherUserId,
    );
    bool isCurrent() =>
        _isActiveSessionGeneration(sessionGeneration) &&
        channelId == _channelId &&
        identical(_screenRoom, room);
    if (!isCurrent()) {
      await _disposeScreenRoom();
      return;
    }
    final participant = room.localParticipant;
    if (participant == null) {
      await _disposeScreenRoom();
      throw OpenSpeakException('屏幕共享节点没有创建本地参与者');
    }
    final limitWindowsResolution =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        quality.resolution != 'source';
    final maxBitrateMbps = token.maxBitrateMbps > 0
        ? token.maxBitrateMbps
        : ScreenShareBitrateLimits.defaults.bitrateMbps(
            quality.resolution,
            quality.fps,
          );
    final parameters = screenShareVideoParameters(
      quality,
      maxBitrateMbps: maxBitrateMbps,
    );
    final track = await lk.LocalVideoTrack.createScreenShareTrack(
      lk.ScreenShareCaptureOptions(
        sourceId: sourceId,
        maxFrameRate: quality.fps.toDouble(),
        params: parameters,
      ),
    );
    if (!isCurrent()) {
      await track.dispose();
      await _disposeScreenRoom();
      return;
    }
    var adjustSender = true;
    // 发布协商开始后 sender 才出现；提前轮询可在首批发送统计可用时立即限制分辨率。
    final earlyWindowsResolutionLimit = limitWindowsResolution
        ? _limitWindowsScreenShareResolution(
            track,
            parameters.dimensions,
            () => adjustSender && isCurrent(),
          )
        : null;
    _screenShareQuality = quality;
    try {
      final publishOptions = screenShareVideoPublishOptions(
        parameters.encoding,
        defaultTargetPlatform,
      );
      final publication = await participant.publishVideoTrack(
        track,
        publishOptions: publishOptions,
      );
      if (publishOptions.videoCodec == 'h264' &&
          track.codec?.toLowerCase() != 'h264') {
        await participant.removePublishedTrack(publication.sid);
        throw OpenSpeakException(
          defaultTargetPlatform == TargetPlatform.macOS
              ? 'macOS 屏幕共享只允许使用硬件 H.264'
              : 'Windows 屏幕共享只允许使用 H.264',
        );
      }
      if (!voiceTrackEncryptionAccepted(
        e2eeRequired: snapshot.voiceToken?.e2eeRequired == true,
        encryptionType: publication.encryptionType,
      )) {
        adjustSender = false;
        await earlyWindowsResolutionLimit;
        await participant.removePublishedTrack(publication.sid);
        throw OpenSpeakException('屏幕共享未启用媒体端到端加密');
      }
      if (!isCurrent()) {
        adjustSender = false;
        await earlyWindowsResolutionLimit;
        return;
      }
      if (limitWindowsResolution) {
        var applied = await earlyWindowsResolutionLimit!;
        if (!applied) {
          applied = await _limitWindowsScreenShareResolution(
            track,
            parameters.dimensions,
            isCurrent,
          );
        }
        if (!applied && isCurrent()) {
          await track.setDegradationPreference(
            lk.DegradationPreference.maintainFramerate,
          );
          ClientLog.write(
            'voice.screen',
            'windows sender dimensions unavailable; '
                'applied frame-rate preference',
          );
        }
      }
      ClientLog.write('voice.screen', 'started quality=${quality.label}');
      unawaited(_pollScreenStats());
      _refreshScreenRoom();
      await _syncVoiceState(throwOnError: true);
    } catch (error, stackTrace) {
      adjustSender = false;
      await earlyWindowsResolutionLimit;
      _screenShareQuality = null;
      try {
        await _disposeScreenRoom();
        await _syncVoiceState();
      } catch (cleanupError, cleanupStackTrace) {
        ClientLog.error(
          'voice.screen.cleanup',
          cleanupError,
          cleanupStackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      adjustSender = false;
    }
  }

  Future<void> stopScreenShare() =>
      _enqueueScreenShareTransition(_stopScreenShare);

  Future<void> _stopScreenShare() async {
    if (_screenRoom == null) return;
    _screenShareQuality = null;
    await _disposeScreenRoom();
    ClientLog.write('voice.screen', 'stopped');
    await _syncVoiceState();
  }

  Future<void> _enqueueScreenShareTransition(
    Future<void> Function() operation,
  ) {
    final queued = _screenShareTransitionTail.then((_) async {
      if (!_disposed) await operation();
    });
    _screenShareTransitionTail = queued.catchError((_) {});
    return queued;
  }

  Future<lk.Room> _connectScreenRoom(
    ScreenShareToken token, {
    required String expectedPublisherUserId,
    bool retryJoinResponseTimeout = true,
  }) async {
    await _disposeScreenRoom();
    final generation = ++_screenRoomGeneration;
    lk.E2EEOptions? encryption;
    if (token.e2eeRequired) {
      final key = _e2eeKey;
      if (key == null ||
          key.length != 32 ||
          token.e2eeEpochId != _e2eeEpochId ||
          !token.e2eeKeyActive) {
        throw OpenSpeakException('当前屏幕共享媒体密钥无效或尚未激活');
      }
      final options = voiceE2EEKeyProviderOptions();
      final keyProvider = lk.BaseKeyProvider(
        await rtc.frameCryptorFactory.createDefaultKeyProvider(options),
        options,
      );
      await keyProvider.setRawKey(key, keyIndex: token.e2eeKeyIndex);
      await keyProvider.setRawKey(key, keyIndex: 1 - token.e2eeKeyIndex);
      encryption = lk.E2EEOptions(keyProvider: keyProvider);
    }
    final room = createOpenSpeakLiveKitRoom(
      roomOptions: lk.RoomOptions(encryption: encryption),
    );
    _screenRoom = room;
    _screenToken = token;
    _expectedScreenPublisherUserId = expectedPublisherUserId;
    room.addListener(_refreshScreenRoom);
    _screenRoomListener = room.createListener()
      ..on<lk.ParticipantConnectedEvent>((_) => _screenRoomChanged())
      ..on<lk.ParticipantDisconnectedEvent>((_) => _screenRoomChanged())
      ..on<lk.TrackPublishedEvent>((_) => _screenRoomChanged())
      ..on<lk.TrackUnpublishedEvent>((_) => _screenRoomChanged())
      ..on<lk.TrackSubscribedEvent>((_) => _screenRoomChanged())
      ..on<lk.TrackUnsubscribedEvent>((_) => _screenRoomChanged())
      ..on<lk.TrackMutedEvent>((_) => _screenRoomChanged())
      ..on<lk.TrackUnmutedEvent>((_) => _screenRoomChanged())
      ..on<lk.RoomReconnectedEvent>((_) => _screenRoomChanged())
      ..on<lk.LocalTrackUnpublishedEvent>((_) {
        if (!_disposingScreenRoom && _screenShareQuality != null) {
          unawaited(_handleLocalScreenShareEnded());
        }
      })
      ..on<lk.RoomDisconnectedEvent>((_) {
        if (!_disposingScreenRoom && identical(_screenRoom, room)) {
          if (token.canPublish) {
            unawaited(_handleLocalScreenShareEnded());
          } else if (_authorizedScreenSharingUserIds.contains(
            expectedPublisherUserId,
          )) {
            unawaited(
              _enqueueScreenShareTransition(
                () => _connectRemoteScreenShare(expectedPublisherUserId),
              ),
            );
          }
        }
      });
    try {
      await room.connect(
        token.url,
        token.token,
        connectOptions: lk.ConnectOptions(
          autoSubscribe: !token.e2eeRequired && !token.canPublish,
          timeouts: _liveKitTimeouts,
        ),
      );
      if (_screenRoomGeneration != generation ||
          !identical(_screenRoom, room)) {
        await _disposeStandaloneScreenRoom(room);
        throw OpenSpeakException('屏幕共享连接已被新的请求替换');
      }
      if (token.e2eeRequired) {
        final manager = room.e2eeManager;
        if (manager == null) {
          throw OpenSpeakException('LiveKit 未能初始化屏幕共享端到端加密');
        }
        final random = math.Random.secure();
        await manager.keyProvider.setSifTrailer(
          Uint8List.fromList(
            List<int>.generate(32, (_) => random.nextInt(256)),
          ),
        );
        await manager.setKeyIndex(token.e2eeKeyIndex);
      }
      if (!token.canPublish) await _applyScreenShareSubscriptions();
      _refreshScreenRoom();
      _startScreenStatsPoll();
      if (!token.canPublish) unawaited(_pollScreenStats());
      return room;
    } catch (error) {
      if (identical(_screenRoom, room)) await _disposeScreenRoom();
      if (!_disposed &&
          retryJoinResponseTimeout &&
          webLiveKitJoinResponseCanRetry(error, isWeb: kIsWeb)) {
        ClientLog.write('voice.screen', 'retrying missed join response');
        return _connectScreenRoom(
          token,
          expectedPublisherUserId: expectedPublisherUserId,
          retryJoinResponseTimeout: false,
        );
      }
      rethrow;
    }
  }

  void _screenRoomChanged() {
    unawaited(_applyScreenShareSubscriptions());
    _refreshScreenRoom();
  }

  void _refreshScreenRoom() {
    if (!_disposed) notifyListeners();
  }

  void _startScreenStatsPoll() {
    _screenStatsTimer?.cancel();
    _screenStatsPreviousPackets = null;
    _screenStatsPreviousLost = null;
    _screenStatsPreviousBytes = null;
    _screenStatsPreviousTimestamp = null;
    _screenStatsPreviousQpSum = null;
    _screenStatsPreviousFramesEncoded = null;
    _screenStatsFailureLogged = false;
    _screenStatsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_pollScreenStats());
    });
  }

  double? _screenPacketLossPercent(num packets, num lost) {
    final previousPackets = _screenStatsPreviousPackets;
    final previousLost = _screenStatsPreviousLost;
    _screenStatsPreviousPackets = packets;
    _screenStatsPreviousLost = lost;
    if (previousPackets == null || previousLost == null) return null;
    final packetDelta = packetCounterDelta(packets, previousPackets);
    final lostDelta = packetCounterDelta(lost, previousLost);
    return _packetLossPercent(total: packetDelta + lostDelta, lost: lostDelta);
  }

  double? _screenBitrate(num? bytes, num? timestamp) {
    final bitrate = rtpBitrateBitsPerSecond(
      bytes: bytes,
      previousBytes: _screenStatsPreviousBytes,
      timestamp: timestamp,
      previousTimestamp: _screenStatsPreviousTimestamp,
      timestampInMicroseconds: !kIsWeb,
    );
    _screenStatsPreviousBytes = bytes;
    _screenStatsPreviousTimestamp = timestamp;
    return bitrate;
  }

  double? _screenAverageQp(num? qpSum, num? framesEncoded) {
    final average = counterAverageDelta(
      total: qpSum,
      previousTotal: _screenStatsPreviousQpSum,
      count: framesEncoded,
      previousCount: _screenStatsPreviousFramesEncoded,
    );
    _screenStatsPreviousQpSum = qpSum;
    _screenStatsPreviousFramesEncoded = framesEncoded;
    return average;
  }

  Future<void> _pollScreenStats() async {
    final room = _screenRoom;
    final token = _screenToken;
    if (room == null ||
        token == null ||
        _screenStatsPollInFlight ||
        _disposed) {
      return;
    }
    _screenStatsPollInFlight = true;
    try {
      if (token.canPublish) {
        final participant = room.localParticipant;
        if (participant == null) return;
        for (final publication in participant.videoTrackPublications) {
          if (publication.source != lk.TrackSource.screenShareVideo ||
              publication.track is! lk.LocalVideoTrack) {
            continue;
          }
          final track = publication.track!;
          final samples = await track.getSenderStats();
          if (samples.isEmpty || !identical(_screenRoom, room)) return;
          final sample = samples.first;
          final sender = track.sender;
          final rawStats = sender == null
              ? const <rtc.StatsReport>[]
              : await sender.getStats();
          if (!identical(_screenRoom, room)) return;
          Map<dynamic, dynamic>? outboundValues;
          for (final report in rawStats) {
            if (report.type == 'outbound-rtp' &&
                (report.id == sample.streamId || outboundValues == null)) {
              outboundValues = report.values;
              if (report.id == sample.streamId) break;
            }
          }
          final bitrate = _screenBitrate(sample.bytesSent, sample.timestamp);
          final averageQp = _screenAverageQp(
            outboundValues?['qpSum'] as num?,
            outboundValues?['framesEncoded'] as num?,
          );
          final targetBitrate = outboundValues?['targetBitrate'] as num?;
          final availableBitrate = selectedCandidatePairValue(
            rawStats,
            'availableOutgoingBitrate',
          );
          int? encodingMinimumBitrate;
          int? encodingMaximumBitrate;
          for (final encoding in sender?.parameters.encodings ?? const []) {
            if (!encoding.active) continue;
            encodingMinimumBitrate ??= encoding.minBitrate;
            encodingMaximumBitrate ??= encoding.maxBitrate;
          }
          final loss = sample.packetsSent == null || sample.packetsLost == null
              ? null
              : _screenPacketLossPercent(
                  sample.packetsSent!,
                  math.max<num>(0, sample.packetsLost!),
                );
          ClientLog.write(
            'voice.screen.stats',
            'direction=publish '
                'resolution=${sample.frameWidth?.round() ?? 0}x'
                '${sample.frameHeight?.round() ?? 0} '
                'fps=${sample.framesPerSecond ?? 0} '
                'bitrate_kbps=${bitrate == null ? 'unknown' : (bitrate / 1000).round()} '
                'target_kbps=${targetBitrate == null ? 'unknown' : (targetBitrate / 1000).round()} '
                'available_kbps=${availableBitrate == null ? 'unknown' : (availableBitrate / 1000).round()} '
                'encoding_min_kbps=${encodingMinimumBitrate == null ? 'unknown' : (encodingMinimumBitrate / 1000).round()} '
                'encoding_max_kbps=${encodingMaximumBitrate == null ? 'unknown' : (encodingMaximumBitrate / 1000).round()} '
                'avg_qp=${averageQp?.toStringAsFixed(1) ?? 'unknown'} '
                'packet_loss_pct=${loss?.toStringAsFixed(2) ?? 'unknown'} '
                'rtt_ms=${sample.roundTripTime == null ? 'unknown' : (sample.roundTripTime! * 1000).toStringAsFixed(1)} '
                'quality_limit=${sample.qualityLimitationReason ?? 'unknown'} '
                'encoder=${sample.encoderImplementation ?? 'unknown'}',
          );
          _screenStatsFailureLogged = false;
          return;
        }
        return;
      }

      final share = activeScreenShare;
      final track = share?.track;
      if (track is! lk.RemoteVideoTrack) return;
      final sample = await track.getReceiverStats();
      if (sample == null || !identical(_screenRoom, room)) return;
      final aspectRatio = screenShareAspectRatioForDimensions(
        sample.frameWidth,
        sample.frameHeight,
      );
      if (aspectRatio != null &&
          (_screenShareAspectRatio == null ||
              (_screenShareAspectRatio! - aspectRatio).abs() > 0.001)) {
        _screenShareAspectRatio = aspectRatio;
        _refreshScreenRoom();
      }
      final receiver = track.receiver;
      final rawStats = receiver == null
          ? const <rtc.StatsReport>[]
          : await receiver.getStats();
      final roundTripTime = selectedCandidatePairRoundTripTime(rawStats);
      if (!identical(_screenRoom, room)) return;
      final bitrate = _screenBitrate(sample.bytesReceived, sample.timestamp);
      final loss = sample.packetsReceived == null || sample.packetsLost == null
          ? null
          : _screenPacketLossPercent(
              sample.packetsReceived!,
              math.max<num>(0, sample.packetsLost!),
            );
      ClientLog.write(
        'voice.screen.stats',
        'direction=receive '
            'resolution=${sample.frameWidth?.round() ?? 0}x'
            '${sample.frameHeight?.round() ?? 0} '
            'fps=${sample.framesPerSecond ?? 0} '
            'bitrate_kbps=${bitrate == null ? 'unknown' : (bitrate / 1000).round()} '
            'packet_loss_pct=${loss?.toStringAsFixed(2) ?? 'unknown'} '
            'rtt_ms=${roundTripTime == null ? 'unknown' : (roundTripTime * 1000).toStringAsFixed(1)} '
            'jitter_ms=${sample.jitter == null ? 'unknown' : (sample.jitter! * 1000).toStringAsFixed(1)} '
            'frames_dropped=${sample.framesDropped?.round() ?? 0} '
            'decoder=${sample.decoderImplementation ?? 'unknown'}',
      );
      _screenStatsFailureLogged = false;
    } catch (error, stackTrace) {
      if (identical(_screenRoom, room) && !_screenStatsFailureLogged) {
        _screenStatsFailureLogged = true;
        ClientLog.error('voice.screen.stats', error, stackTrace);
      }
    } finally {
      _screenStatsPollInFlight = false;
    }
  }

  Future<void> _handleLocalScreenShareEnded() =>
      _enqueueScreenShareTransition(_handleLocalScreenShareEndedNow);

  Future<void> _handleLocalScreenShareEndedNow() async {
    if (_screenShareQuality == null) return;
    _screenShareQuality = null;
    await _disposeScreenRoom();
    ClientLog.write('voice.screen', 'ended by system');
    await _syncVoiceState();
  }

  Future<void> _disposeScreenRoom() async {
    _screenStatsTimer?.cancel();
    _screenStatsTimer = null;
    _screenStatsPreviousPackets = null;
    _screenStatsPreviousLost = null;
    _screenStatsPreviousBytes = null;
    _screenStatsPreviousTimestamp = null;
    _screenStatsPreviousQpSum = null;
    _screenStatsPreviousFramesEncoded = null;
    _screenShareAspectRatio = null;
    _screenRoomGeneration += 1;
    _screenViewerRequestGeneration += 1;
    final room = _screenRoom;
    final listener = _screenRoomListener;
    _screenRoom = null;
    _screenRoomListener = null;
    _screenToken = null;
    _expectedScreenPublisherUserId = null;
    if (room == null) {
      await listener?.dispose();
      return;
    }
    _disposingScreenRoom = true;
    try {
      room.removeListener(_refreshScreenRoom);
      await listener?.dispose();
      await _disposeStandaloneScreenRoom(room);
    } finally {
      _disposingScreenRoom = false;
      _refreshScreenRoom();
    }
  }

  Future<void> _disposeStandaloneScreenRoom(lk.Room room) => closeVoiceRoom(
    sendLeave: () async {
      // ignore: invalid_use_of_internal_member
      await room.engine.disconnect();
    },
    dispose: room.dispose,
  );

  void registerMicrophonePreviewReleaseHandler(
    Object owner,
    Future<void> Function() release,
  ) {
    _microphonePreviewOwner = owner;
    _releaseMicrophonePreview = release;
  }

  void unregisterMicrophonePreviewReleaseHandler(Object owner) {
    if (!identical(_microphonePreviewOwner, owner)) return;
    _microphonePreviewOwner = null;
    _releaseMicrophonePreview = null;
  }

  Future<void> join({
    required OpenSpeakApi api,
    required String authToken,
    required String serverId,
    required String channelId,
    String localUserId = '',
    Set<String> channelMemberUserIds = const {},
    int? requestGeneration,
    Uint8List? e2eeKey,
    String e2eeDeviceId = '',
    String e2eeEpochId = '',
    bool reconnectAttempt = false,
  }) async {
    if (requestGeneration != null &&
        !_isActiveSessionGeneration(requestGeneration)) {
      return;
    }
    final nextE2EEKey = Uint8List.fromList(
      e2eeKey ?? (reconnectAttempt ? _e2eeKey ?? const <int>[] : const <int>[]),
    );
    final nextE2EEDeviceId = e2eeDeviceId.isNotEmpty
        ? e2eeDeviceId
        : reconnectAttempt
        ? _e2eeDeviceId
        : '';
    final nextE2EEEpochId = e2eeEpochId.isNotEmpty
        ? e2eeEpochId
        : reconnectAttempt
        ? _e2eeEpochId
        : '';
    final nextLocalUserId = localUserId.isNotEmpty
        ? localUserId
        : reconnectAttempt
        ? _localUserId
        : '';
    final generation = requestGeneration ?? _sessionGeneration + 1;
    var liveKitConnected = false;
    var syncingVoiceState = false;
    _sessionGeneration = generation;
    _cancelLiveKitReconnect(resetAttempts: !reconnectAttempt);
    await leave(
      clearVoiceState: false,
      notifyServer: false,
      intentional: false,
      cancelActiveJoin: false,
    );
    if (!_isActiveSessionGeneration(generation)) return;
    _intentionalLeave = false;
    if (!reconnectAttempt) {
      _liveKitReconnectAttempts = 0;
    }
    _api = api;
    _authToken = authToken;
    _serverId = serverId;
    _localUserId = nextLocalUserId;
    _channelId = channelId;
    _channelMemberUserIds = Set<String>.from(channelMemberUserIds);
    _persistentChannelSwitchIsolated = false;
    _clearE2EEKey();
    _e2eeKey = nextE2EEKey.isEmpty ? null : nextE2EEKey;
    _e2eeDeviceId = nextE2EEDeviceId;
    _e2eeEpochId = nextE2EEEpochId;
    _setSnapshot(
      snapshot.copyWith(
        connecting: true,
        connected: false,
        reconnecting: false,
        status: '正在连接 LiveKit',
        remoteParticipants: 0,
        remoteAudioTracks: 0,
        liveKitParticipantUserIds: const {},
        liveKitSpeakingUserIds: const {},
        remoteAudioBitrate: 0,
        remoteAudioBytesReceived: 0,
        clearVoiceState: !reconnectAttempt,
        clearMediaNetworkStats: true,
      ),
    );

    try {
      ClientLog.write('voice.room', 'token start channel=$channelId');
      final token = await api.getVoiceToken(
        authToken,
        channelId,
        deviceId: _e2eeDeviceId,
        e2eeEpochId: _e2eeEpochId,
      );
      ClientLog.write('voice.room', 'token done channel=$channelId');
      if (!_isActiveSessionGeneration(generation)) return;
      if (token.token.isEmpty || token.url.isEmpty) {
        throw OpenSpeakException('voice-token 响应缺少 LiveKit url/token');
      }
      if (!voiceE2EEConfigurationValid(
        token: token,
        key: _e2eeKey,
        deviceId: _e2eeDeviceId,
        epochId: _e2eeEpochId,
      )) {
        throw OpenSpeakException('当前媒体端到端加密密钥无效或已轮换');
      }
      _activeE2EEKeyIndex = token.e2eeKeyIndex;
      _stagedE2EEKeyIndex = token.e2eeKeyActive ? null : token.e2eeKeyIndex;
      _e2eeMediaActive = !token.e2eeRequired || token.e2eeKeyActive;
      _e2eeParticipantKeys = voiceE2EEUsesParticipantKeys(token);
      _setSnapshot(
        snapshot.copyWith(
          voiceToken: token,
          status: '正在连接 LiveKit: ${token.url}',
        ),
      );

      lk.E2EEOptions? encryption;
      if (token.e2eeRequired) {
        final options = voiceE2EEKeyProviderOptions(
          sharedKey: !_e2eeParticipantKeys,
        );
        final keyProvider = lk.BaseKeyProvider(
          await rtc.frameCryptorFactory.createDefaultKeyProvider(options),
          options,
        );
        if (_e2eeParticipantKeys) {
          await _installParticipantKeys(
            keyProvider,
            _e2eeKey!,
            _channelMemberUserIds,
            token.e2eeKeyIndex,
            mirror: true,
          );
        } else {
          await keyProvider.setRawKey(_e2eeKey!, keyIndex: token.e2eeKeyIndex);
          await keyProvider.setRawKey(
            _e2eeKey!,
            keyIndex: 1 - token.e2eeKeyIndex,
          );
        }
        encryption = lk.E2EEOptions(keyProvider: keyProvider);
      }
      final room = createOpenSpeakLiveKitRoom(
        roomOptions: lk.RoomOptions(
          defaultAudioCaptureOptions: _audioCaptureOptions,
          defaultAudioPublishOptions: voiceAudioPublishOptions(
            token.voiceAudioBitrateKbps,
          ),
          encryption: encryption,
        ),
      );
      _room = room;
      _connectingRoom = room;
      try {
        _attachRoomListener(room);
        lk.LocalAudioTrack? fastConnectTrack;
        if (_webMicrophoneUnavailable) {
          _enableWebListenOnlyMode();
        } else if (_shouldKeepMicrophoneTrack()) {
          try {
            fastConnectTrack = await _ensureMicrophoneCapture(room);
          } catch (error) {
            if (!webMicrophoneCaptureCanFallBackToListenOnly(
              error,
              isWeb: kIsWeb,
            )) {
              rethrow;
            }
            _enableWebListenOnlyMode();
          }
        }
        if (!_isActiveSessionGeneration(generation) ||
            !identical(_room, room)) {
          await _disposeSpecificRoom(room);
          return;
        }
        await _syncMicrophoneMonitor(
          fastConnectTrack,
          windowsUseWebRtc: windowsMicrophoneLevelUsesWebRtc(
            fastConnecting: true,
            transmitting: false,
          ),
        );
        fastConnectTrack?.mediaStreamTrack.enabled = false;
        ClientLog.write('voice.room', 'connect start channel=$channelId');
        await room.connect(
          token.url,
          token.token,
          connectOptions: lk.ConnectOptions(
            autoSubscribe: voiceShouldAutoSubscribe(
              listenOff: snapshot.listenOff,
              e2eeRequired: token.e2eeRequired,
              persistentRoom: token.roomScope == 'server',
            ),
            timeouts: _liveKitTimeouts,
          ),
          fastConnectOptions:
              fastConnectTrack == null || token.roomScope == 'server'
              ? null
              : lk.FastConnectOptions(
                  microphone: lk.TrackOption<bool, lk.LocalAudioTrack>(
                    track: fastConnectTrack,
                  ),
                ),
        );
        _syncRemoteParticipantListeners(room);
        if (token.e2eeRequired) {
          final e2eeManager = room.e2eeManager;
          if (e2eeManager == null) {
            throw OpenSpeakException('LiveKit 未能初始化媒体端到端加密');
          }
          final random = math.Random.secure();
          await e2eeManager.keyProvider.setSifTrailer(
            Uint8List.fromList(
              List<int>.generate(32, (_) => random.nextInt(256)),
            ),
          );
          await e2eeManager.setKeyIndex(_activeE2EEKeyIndex);
        }
      } finally {
        if (identical(_connectingRoom, room)) _connectingRoom = null;
      }
      liveKitConnected = true;
      ClientLog.write(
        'voice.room',
        'connect done channel=$channelId '
            'remote=${room.remoteParticipants.length}',
      );
      if (!_isActiveSessionGeneration(generation)) {
        await _disposeSpecificRoom(room);
        return;
      }
      await _applyAudioDevices();
      if (!_isActiveSessionGeneration(generation)) return;
      await _applyMediaRouting();
      if (!_isActiveSessionGeneration(generation)) return;
      syncingVoiceState = true;
      final state = await _setVoiceStateWhenRealtimeReady(
        api,
        authToken,
        serverId,
        channelId,
        muted: snapshot.muted,
        deafened: snapshot.listenOff,
        speaking: snapshot.speaking,
      );
      syncingVoiceState = false;
      if (!_isActiveSessionGeneration(generation)) return;
      _cancelLiveKitReconnect(resetAttempts: true);
      _setSnapshot(
        snapshot.copyWith(
          connecting: false,
          connected: true,
          reconnecting: false,
          status: '已连接 ${token.room}',
          voiceToken: token,
          voiceState: state,
        ),
      );
      _startSpeakingPoll();
      _startAudioStatsPoll();
      _refreshRoomSnapshot();
    } catch (error, stackTrace) {
      if (!_isActiveSessionGeneration(generation)) return;
      ClientLog.error('voice.room', error, stackTrace);
      final failedUrl = snapshot.voiceToken?.url;
      final failureStatus = voiceJoinFailureStatus(
        liveKitConnected: liveKitConnected,
        syncingVoiceState: syncingVoiceState,
        failedUrl: failedUrl,
      );
      final retryJoinResponse = webLiveKitJoinResponseCanRetry(
        error,
        isWeb: kIsWeb,
      );
      final preserveVoiceState =
          (reconnectAttempt || retryJoinResponse) && !_intentionalLeave;
      await _disposeRoom();
      _setSnapshot(
        snapshot.copyWith(
          connecting: false,
          connected: false,
          reconnecting: preserveVoiceState,
          status: failureStatus,
          remoteParticipants: 0,
          remoteAudioTracks: 0,
          liveKitParticipantUserIds: const {},
          liveKitSpeakingUserIds: const {},
          remoteAudioBitrate: 0,
          remoteAudioBytesReceived: 0,
          speaking: false,
          clearVoiceState: !preserveVoiceState,
          clearMediaNetworkStats: true,
        ),
      );
      if (preserveVoiceState) {
        if (retryJoinResponse && !reconnectAttempt) {
          ClientLog.write('voice.room', 'retrying missed join response');
        }
        _scheduleLiveKitReconnect();
      }
      if (retryJoinResponse && !reconnectAttempt) return;
      if (liveKitConnected) {
        throw OpenSpeakException(
          '$failureStatus: $error',
          statusCode: error is OpenSpeakException ? error.statusCode : 0,
          code: error is OpenSpeakException ? error.code : '',
          secureUrl: error is OpenSpeakException ? error.secureUrl : '',
          plainUrl: error is OpenSpeakException ? error.plainUrl : '',
        );
      }
      throw OpenSpeakException(_describeLiveKitError(error, failedUrl));
    }
  }

  String _describeLiveKitError(Object error, String? url) {
    final target = url == null || url.isEmpty ? '未知 LiveKit URL' : url;
    final hint = _loopbackHint(url);
    return 'LiveKit 连接失败: $target。$hint 原始错误: $error';
  }

  Future<VoiceState> _setVoiceStateWhenRealtimeReady(
    OpenSpeakApi api,
    String authToken,
    String serverId,
    String channelId, {
    required bool muted,
    required bool deafened,
    required bool speaking,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 12; attempt += 1) {
      try {
        return await api.setVoiceState(
          authToken,
          serverId,
          channelId,
          muted: muted,
          deafened: deafened,
          speaking: speaking,
          screenSharing: isScreenSharing,
          screenShareResolution: _screenShareQuality?.resolution ?? '',
          screenShareFPS: _screenShareQuality?.fps ?? 0,
          screenShareMediaNodeId: _screenToken?.mediaNodeId ?? '',
        );
      } on OpenSpeakException catch (error) {
        lastError = error;
        if (voiceStateSyncShouldRejoinChannel(error)) {
          final userId = _room?.localParticipant?.identity ?? '';
          if (userId.isEmpty || attempt == 11) rethrow;
          try {
            await api.joinChannel(authToken, channelId, userId: userId);
            continue;
          } on OpenSpeakException catch (joinError) {
            lastError = joinError;
            if (!voiceStateSyncShouldRetry(joinError) || attempt == 11) {
              rethrow;
            }
            await Future<void>.delayed(const Duration(milliseconds: 150));
            continue;
          }
        }
        final shouldRetry = voiceStateSyncShouldRetry(error);
        if (!shouldRetry || attempt == 11) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    throw lastError ?? OpenSpeakException('无法同步语音状态');
  }

  String _loopbackHint(String? url) {
    final parsed = Uri.tryParse(url ?? '');
    final host = parsed?.host.toLowerCase() ?? '';
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return '这个地址指向当前客户端机器；如果 LiveKit 在服务器上，请把 media node 的 livekit_url 改成客户端可访问的服务器 IP/域名。';
    }
    return '请确认 LiveKit 服务正在监听，并且客户端能访问该地址和端口。';
  }

  Future<void> leave({
    required bool clearVoiceState,
    bool notifyServer = true,
    bool notifyListeners = true,
    bool intentional = true,
    bool cancelActiveJoin = true,
  }) async {
    if (cancelActiveJoin) {
      _sessionGeneration += 1;
    }
    if (intentional) {
      _intentionalLeave = true;
      _cancelLiveKitReconnect(resetAttempts: true);
    }
    await _enqueueScreenShareTransition(
      () => _leave(
        clearVoiceState: clearVoiceState,
        notifyServer: notifyServer,
        notifyListeners: notifyListeners,
        intentional: intentional,
      ),
    );
  }

  Future<void> _leave({
    required bool clearVoiceState,
    required bool notifyServer,
    required bool notifyListeners,
    required bool intentional,
  }) async {
    await _disposeScreenRoom();
    await _disposeRoom();
    _channelMemberUserIds = const {};
    _authorizedScreenSharingUserIds = const {};
    _screenShareQuality = null;
    _persistentChannelSwitchIsolated = false;
    _speakingSyncTimer?.cancel();
    _speakingSyncTimer = null;
    _speakingPollTimer?.cancel();
    _speakingPollTimer = null;
    _audioStatsTimer?.cancel();
    _audioStatsTimer = null;

    final api = _api;
    final authToken = _authToken;
    final serverId = _serverId;
    if (clearVoiceState &&
        notifyServer &&
        api != null &&
        authToken != null &&
        serverId != null) {
      await api.clearVoiceState(authToken, serverId);
    }

    _setSnapshot(
      snapshot.copyWith(
        connecting: false,
        connected: false,
        reconnecting: false,
        status: '未连接',
        remoteParticipants: 0,
        remoteAudioTracks: 0,
        liveKitParticipantUserIds: const {},
        liveKitSpeakingUserIds: const {},
        remoteAudioBitrate: 0,
        remoteAudioBytesReceived: 0,
        speaking: false,
        clearVoiceState: clearVoiceState,
        clearMediaNetworkStats: true,
      ),
      notify: notifyListeners,
    );
    if (intentional) _clearE2EEKey();
  }

  Future<void> setMuted(bool value) async {
    final nextMuted = value || snapshot.listenOff || _webMicrophoneUnavailable;
    _setSnapshot(snapshot.copyWith(muted: nextMuted));
    await _applyMicrophonePublishing();
    if (nextMuted) {
      _setLocalSpeaking(false);
    }
    await _syncVoiceState();
  }

  void _enableWebListenOnlyMode() {
    _webMicrophoneUnavailable = true;
    _setSnapshot(snapshot.copyWith(muted: true, status: '未发现可用麦克风，正在以只听模式连接'));
    ClientLog.write(
      'voice.mic',
      'capture unavailable; continuing in listen-only mode',
    );
  }

  Future<void> setListenOff(bool value) async {
    _setSnapshot(
      snapshot.copyWith(
        listenOff: value,
        muted: value || _webMicrophoneUnavailable,
        speaking: value ? false : snapshot.speaking,
      ),
    );
    await _applyListenOffToRoom();
    await _applyMicrophonePublishing();
    await _syncVoiceState();
  }

  Future<void> configureAudioDevices({
    required String? inputDeviceId,
    required String? outputDeviceId,
    bool restartInput = false,
    bool inputAvailable = true,
  }) async {
    final inputChanged = _audioInputDeviceId != inputDeviceId;
    _audioInputDeviceId = inputDeviceId;
    _audioOutputDeviceId = outputDeviceId;
    if (kIsWeb) {
      _webMicrophoneUnavailable = !inputAvailable;
      if (_webMicrophoneUnavailable && !snapshot.muted) {
        _setSnapshot(snapshot.copyWith(muted: true));
      }
    }
    ClientLog.write(
      'voice.mic',
      'configure start input=${inputDeviceId ?? 'system'} '
          'remote=${_room?.remoteParticipants.length ?? 0} '
          'changed=$inputChanged restart=$restartInput '
          'available=$inputAvailable',
    );
    try {
      await _applyAudioDevices();
      ClientLog.write('voice.mic', 'device route applied');
      if (!inputAvailable) {
        if (kIsWeb) {
          await _applyMicrophonePublishing();
          await _syncVoiceState();
        }
        return;
      }
      if (!inputChanged && !restartInput) return;
      if (microphoneCaptureRestartShouldDefer(
        roomConnecting: identical(_connectingRoom, _room),
        restartRequested: true,
      )) {
        _microphoneCaptureRestartPending = true;
        ClientLog.write(
          'voice.mic',
          'capture restart deferred until connected',
        );
        return;
      }
      await _resetMicrophoneCapture();
      await _applyMicrophonePublishing();
      ClientLog.write('voice.mic', 'configure done');
    } catch (error, stackTrace) {
      ClientLog.error('voice.mic', error, stackTrace);
      rethrow;
    }
  }

  Future<void> configureMicrophoneActivation({
    required MicrophoneActivationMode mode,
    required double threshold,
  }) async {
    _microphoneActivationMode = mode;
    _microphoneThreshold = threshold.clamp(0.0, 1.0).toDouble();
    if (mode != MicrophoneActivationMode.voiceThreshold) {
      _thresholdGateReleaseTimer?.cancel();
      _thresholdGateReleaseTimer = null;
      _thresholdGateOpen = false;
      _thresholdReleaseAt = null;
    }
    await _applyMicrophonePublishing();
  }

  Future<void> setPushToTalkPressed(bool pressed) async {
    if (_pushToTalkPressed == pressed) return;
    _pushToTalkPressed = pressed;
    await _applyMicrophonePublishing();
    if (!pressed &&
        _microphoneActivationMode == MicrophoneActivationMode.pushToTalk) {
      _setLocalSpeaking(false);
    }
  }

  Future<void> setNoiseSuppressionEnabled(bool enabled) async {
    if (_noiseSuppressionEnabled == enabled) return;
    final previous = _noiseSuppressionEnabled;
    _noiseSuppressionEnabled = enabled;
    try {
      await _resetMicrophoneCapture();
      await _applyMicrophonePublishing();
    } catch (_) {
      _noiseSuppressionEnabled = previous;
      await _resetMicrophoneCapture();
      await _applyMicrophonePublishing();
      rethrow;
    }
  }

  Future<void> setOutputVolume(double value) async {
    _outputVolume = value.clamp(0.0, 1.0).toDouble();
    await _applyOutputVolumeToRoom();
  }

  Future<void> setParticipantOutputVolume(String userId, double value) async {
    final next = value.clamp(0.0, 2.0).toDouble();
    if (next == 1.0) {
      _participantOutputVolumes.remove(userId);
    } else {
      _participantOutputVolumes[userId] = next;
    }
    final room = _room;
    if (room == null || snapshot.listenOff) return;
    for (final participant in room.remoteParticipants.values) {
      if (participant.identity != userId) continue;
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (!publication.subscribed || track == null) continue;
        await rtc.Helper.setVolume(
          effectiveParticipantOutputVolume(_outputVolume, next),
          track.mediaStreamTrack,
        );
      }
    }
  }

  Future<void> setExternalVoiceState(VoiceState? state) async {
    _setSnapshot(
      snapshot.copyWith(voiceState: state, clearVoiceState: state == null),
    );
  }

  Future<void> setExternalVoiceToken(VoiceToken token) async {
    if (_room != null &&
        voiceTokenRequiresRoomReconnect(snapshot.voiceToken, token)) {
      throw OpenSpeakException('语音房间拓扑已变化，需要重新连接');
    }
    _e2eeParticipantKeys = voiceE2EEUsesParticipantKeys(token);
    _setSnapshot(snapshot.copyWith(voiceToken: token));
  }

  Set<String> _e2eeParticipantIds(Iterable<String> userIds) => {
    for (final userId in userIds)
      if (userId.isNotEmpty) userId,
    if (_localUserId.isNotEmpty) _localUserId,
  };

  Future<void> _installParticipantKeys(
    lk.BaseKeyProvider keyProvider,
    Uint8List key,
    Iterable<String> userIds,
    int keyIndex, {
    required bool mirror,
  }) async {
    for (final install in voiceE2EEParticipantKeyInstallPlan(
      participantIds: userIds,
      localUserId: _localUserId,
      keyIndex: keyIndex,
      mirror: mirror,
    )) {
      await keyProvider.setRawKey(
        key,
        participantId: install.participantId,
        keyIndex: install.keyIndex,
      );
    }
  }

  Future<void> _setParticipantKeyIndex(
    lk.E2EEManager manager,
    Iterable<String> userIds,
    int keyIndex,
  ) async {
    for (final userId in _e2eeParticipantIds(userIds)) {
      await manager.setKeyIndex(keyIndex, participantIdentity: userId);
    }
  }

  Future<void> stageE2EEMediaKey({
    required Uint8List key,
    required String epochId,
    required int keyIndex,
  }) async {
    final room = _room;
    final manager = room?.e2eeManager;
    if (room == null || manager == null || key.length != 32) {
      throw OpenSpeakException('当前语音会话无法安装新的媒体密钥');
    }
    if (keyIndex != 0 && keyIndex != 1) {
      throw OpenSpeakException('媒体密钥槽位无效');
    }
    if (_e2eeEpochId == epochId && _stagedE2EEKeyIndex == keyIndex) return;
    _e2eeOldKeyRetireTimer?.cancel();
    _e2eeOldKeyRetireTimer = null;
    _retiringE2EEKey?.fillRange(0, _retiringE2EEKey!.length, 0);
    _retiringE2EEKey = null;
    final nextKey = Uint8List.fromList(key);
    if (_e2eeParticipantKeys) {
      final currentKey = _e2eeKey;
      if (_e2eeMediaActive &&
          currentKey != null &&
          keyIndex == _activeE2EEKeyIndex) {
        throw OpenSpeakException('新的媒体密钥必须安装到备用槽位');
      }
      await _installParticipantKeys(
        manager.keyProvider,
        nextKey,
        _channelMemberUserIds,
        keyIndex,
        mirror: false,
      );
      if (_e2eeMediaActive && currentKey != null) {
        _retiringE2EEKey = Uint8List.fromList(currentKey);
        // Keep the active slot as LiveKit's latest participant slot until the
        // staged epoch is activated, including for tracks subscribed meanwhile.
        await _installParticipantKeys(
          manager.keyProvider,
          _retiringE2EEKey!,
          _channelMemberUserIds,
          _activeE2EEKeyIndex,
          mirror: false,
        );
      }
    } else {
      await manager.keyProvider.setRawKey(nextKey, keyIndex: keyIndex);
    }
    await _screenRoom?.e2eeManager?.keyProvider.setRawKey(
      nextKey,
      keyIndex: keyIndex,
    );
    _e2eeKey?.fillRange(0, _e2eeKey!.length, 0);
    _e2eeKey = nextKey;
    _e2eeEpochId = epochId;
    _stagedE2EEKeyIndex = keyIndex;
    final token = snapshot.voiceToken;
    if (token != null) {
      _setSnapshot(
        snapshot.copyWith(
          voiceToken: token.copyWith(
            e2eeEpochId: epochId,
            e2eeKeyIndex: keyIndex,
            e2eeKeyActive: false,
            mediaKeySlots: true,
          ),
        ),
      );
    }
    ClientLog.write(
      'voice.e2ee',
      'media key staged epoch=$epochId index=$keyIndex',
    );
  }

  Future<void> activateE2EEMediaKey({
    required String epochId,
    required int keyIndex,
  }) async {
    if (keyIndex != 0 && keyIndex != 1) {
      throw OpenSpeakException('媒体密钥槽位无效');
    }
    final room = _room;
    final manager = room?.e2eeManager;
    if (room == null || manager == null || _e2eeEpochId != epochId) return;
    if (_stagedE2EEKeyIndex != null && _stagedE2EEKeyIndex != keyIndex) {
      return;
    }
    if (_e2eeParticipantKeys) {
      final key = _e2eeKey;
      if (key == null) return;
      // Staging keeps the old slot latest so newly subscribed tracks continue
      // to decrypt. Mark the activated slot latest before opening media again.
      await _installParticipantKeys(
        manager.keyProvider,
        key,
        _channelMemberUserIds,
        keyIndex,
        mirror: false,
      );
      await _setParticipantKeyIndex(manager, _channelMemberUserIds, keyIndex);
    } else {
      await manager.setKeyIndex(keyIndex);
    }
    await _screenRoom?.e2eeManager?.setKeyIndex(keyIndex);
    _activeE2EEKeyIndex = keyIndex;
    _stagedE2EEKeyIndex = null;
    _e2eeMediaActive = true;
    final token = snapshot.voiceToken;
    if (token != null) {
      _setSnapshot(
        snapshot.copyWith(
          voiceToken: token.copyWith(
            e2eeEpochId: epochId,
            e2eeKeyIndex: keyIndex,
            e2eeKeyActive: true,
            mediaKeySlots: true,
          ),
        ),
      );
    }
    await _applyMicrophonePublishing();
    await _applyListenOffToRoom();
    _scheduleOldE2EEKeyRetirement(epochId, keyIndex);
    ClientLog.write(
      'voice.e2ee',
      'media key activated epoch=$epochId index=$keyIndex',
    );
  }

  Future<void> isolatePersistentRoomForChannelSwitch() =>
      _enqueueScreenShareTransition(_isolatePersistentRoomForChannelSwitch);

  Future<void> _isolatePersistentRoomForChannelSwitch() async {
    final room = _room;
    if (!canSwitchPersistentChannel || room == null) return;
    _persistentChannelSwitchIsolated = true;
    if (isScreenSharing) {
      await _stopScreenShare();
    } else {
      await _disposeScreenRoom();
    }
    final localUserId = room.localParticipant?.identity;
    _channelMemberUserIds = {
      if (localUserId != null && localUserId.isNotEmpty) localUserId,
    };
    await _applyMicrophonePublishing();
    await _applyMediaRouting();
  }

  Future<void> _configurePersistentChannelE2EE({
    required Uint8List? key,
    required String epochId,
    required int keyIndex,
    required bool keyActive,
    required bool mediaKeySlots,
    required Set<String> channelMemberUserIds,
  }) async {
    final token = snapshot.voiceToken;
    if (token?.e2eeRequired != true) return;
    final manager = _room?.e2eeManager;
    if (!_e2eeParticipantKeys ||
        manager == null ||
        key == null ||
        key.length != 32 ||
        epochId.isEmpty) {
      throw OpenSpeakException('当前持久语音会话无法安装频道媒体密钥');
    }
    if (keyIndex != 0 && keyIndex != 1) {
      throw OpenSpeakException('媒体密钥槽位无效');
    }

    _e2eeOldKeyRetireTimer?.cancel();
    _e2eeOldKeyRetireTimer = null;
    _retiringE2EEKey?.fillRange(0, _retiringE2EEKey!.length, 0);
    _retiringE2EEKey = null;
    final nextKey = Uint8List.fromList(key);
    await _installParticipantKeys(
      manager.keyProvider,
      nextKey,
      channelMemberUserIds,
      keyIndex,
      mirror: keyActive,
    );
    if (keyActive) {
      await _setParticipantKeyIndex(manager, channelMemberUserIds, keyIndex);
      _activeE2EEKeyIndex = keyIndex;
      _stagedE2EEKeyIndex = null;
    } else {
      _stagedE2EEKeyIndex = keyIndex;
    }
    _e2eeMediaActive = keyActive;
    _e2eeKey?.fillRange(0, _e2eeKey!.length, 0);
    _e2eeKey = nextKey;
    _e2eeEpochId = epochId;
    _setSnapshot(
      snapshot.copyWith(
        voiceToken: token!.copyWith(
          e2eeEpochId: epochId,
          e2eeKeyIndex: keyIndex,
          e2eeKeyActive: keyActive,
          mediaKeySlots: mediaKeySlots,
        ),
      ),
    );
  }

  Future<void> switchPersistentChannel({
    required String channelId,
    required Set<String> channelMemberUserIds,
    required int requestGeneration,
    Uint8List? e2eeKey,
    String e2eeEpochId = '',
    int e2eeKeyIndex = 0,
    bool e2eeKeyActive = true,
    bool mediaKeySlots = false,
  }) async {
    final room = _room;
    final api = _api;
    final authToken = _authToken;
    final serverId = _serverId;
    if (!canSwitchPersistentChannel ||
        room == null ||
        api == null ||
        authToken == null ||
        serverId == null) {
      throw OpenSpeakException('当前语音会话不支持无重连切换频道');
    }
    if (!_isActiveSessionGeneration(requestGeneration)) return;
    if (_channelId == channelId) {
      _persistentChannelSwitchIsolated = false;
      if (snapshot.voiceToken?.e2eeRequired == true && !e2eeKeyActive) {
        if (e2eeKey == null) {
          throw OpenSpeakException('当前持久语音会话无法安装频道媒体密钥');
        }
        await stageE2EEMediaKey(
          key: e2eeKey,
          epochId: e2eeEpochId,
          keyIndex: e2eeKeyIndex,
        );
      } else {
        await _configurePersistentChannelE2EE(
          key: e2eeKey,
          epochId: e2eeEpochId,
          keyIndex: e2eeKeyIndex,
          keyActive: e2eeKeyActive,
          mediaKeySlots: mediaKeySlots,
          channelMemberUserIds: channelMemberUserIds,
        );
      }
      if (!_isActiveSessionGeneration(requestGeneration)) return;
      await updateChannelMembers(channelMemberUserIds);
      await _applyMediaRouting();
      return;
    }
    await isolatePersistentRoomForChannelSwitch();
    if (!_isActiveSessionGeneration(requestGeneration)) return;

    final localUserId = room.localParticipant?.identity;
    await _configurePersistentChannelE2EE(
      key: e2eeKey,
      epochId: e2eeEpochId,
      keyIndex: e2eeKeyIndex,
      keyActive: e2eeKeyActive,
      mediaKeySlots: mediaKeySlots,
      channelMemberUserIds: channelMemberUserIds,
    );
    if (!_isActiveSessionGeneration(requestGeneration)) return;
    final state = await _setVoiceStateWhenRealtimeReady(
      api,
      authToken,
      serverId,
      channelId,
      muted: snapshot.muted,
      deafened: snapshot.listenOff,
      speaking: false,
    );
    if (!_isActiveSessionGeneration(requestGeneration)) return;
    _channelId = channelId;
    _channelMemberUserIds = Set<String>.from(channelMemberUserIds);
    if (localUserId != null && localUserId.isNotEmpty) {
      _channelMemberUserIds.add(localUserId);
    }
    _persistentChannelSwitchIsolated = false;
    _setSnapshot(
      snapshot.copyWith(
        voiceToken: snapshot.voiceToken?.copyWith(
          channelId: channelId,
          e2eeEpochId: e2eeEpochId.isEmpty ? null : e2eeEpochId,
          e2eeKeyIndex: e2eeEpochId.isEmpty ? null : e2eeKeyIndex,
          e2eeKeyActive: e2eeEpochId.isEmpty ? null : e2eeKeyActive,
          mediaKeySlots: e2eeEpochId.isEmpty ? null : mediaKeySlots,
        ),
        voiceState: state,
        speaking: false,
        status: '已连接 ${snapshot.voiceToken?.room ?? ''}'.trim(),
        clearMediaNetworkStats: true,
      ),
    );
    await _applyMediaRouting();
    ClientLog.write(
      'voice.channel',
      'switched channel=$channelId without reconnect',
    );
  }

  Future<void> updateChannelMembers(Set<String> userIds) async {
    if (!usesPersistentRoom || _persistentChannelSwitchIsolated) return;
    final next = Set<String>.from(userIds);
    final localUserId = _room?.localParticipant?.identity;
    if (localUserId != null && localUserId.isNotEmpty) next.add(localUserId);
    if (setEquals(_channelMemberUserIds, next)) return;
    if (_e2eeParticipantKeys) {
      final manager = _room?.e2eeManager;
      final key = _e2eeKey;
      if (manager != null && key != null) {
        final added = next.difference(_channelMemberUserIds);
        final stagedIndex = _stagedE2EEKeyIndex;
        await _installParticipantKeys(
          manager.keyProvider,
          key,
          added,
          stagedIndex ?? _activeE2EEKeyIndex,
          mirror: stagedIndex == null,
        );
        if (stagedIndex == null) {
          await _setParticipantKeyIndex(manager, added, _activeE2EEKeyIndex);
        } else if (_retiringE2EEKey != null) {
          await _installParticipantKeys(
            manager.keyProvider,
            _retiringE2EEKey!,
            added,
            _activeE2EEKeyIndex,
            mirror: false,
          );
        }
      }
    }
    _channelMemberUserIds = next;
    await _applyMediaRouting();
  }

  Future<void> updateAuthorizedScreenShares(Set<String> userIds) async {
    final next = Set<String>.from(userIds);
    _authorizedScreenSharingUserIds = next;
    await _enqueueScreenShareTransition(
      () => _updateAuthorizedScreenShares(next),
    );
  }

  Future<void> _updateAuthorizedScreenShares(
    Set<String> expectedUserIds,
  ) async {
    if (!setEquals(_authorizedScreenSharingUserIds, expectedUserIds)) return;
    final localUserId = _room?.localParticipant?.identity;
    final remoteUserId = expectedUserIds
        .where((userId) => userId != localUserId)
        .firstOrNull;
    if (_screenToken?.canPublish == true) {
      await _applyScreenShareSubscriptions();
      return;
    }
    if (remoteUserId == null) {
      await _disposeScreenRoom();
      return;
    }
    if (_screenRoom == null ||
        _expectedScreenPublisherUserId != remoteUserId ||
        _screenToken?.canPublish != false) {
      await _connectRemoteScreenShare(remoteUserId);
    }
    await _applyScreenShareSubscriptions();
    _refreshScreenRoom();
  }

  Future<void> _connectRemoteScreenShare(String publisherUserId) async {
    final api = _api;
    final authToken = _authToken;
    final channelId = _channelId;
    if (api == null ||
        authToken == null ||
        channelId == null ||
        !snapshot.connected) {
      return;
    }
    final requestGeneration = ++_screenViewerRequestGeneration;
    try {
      final token = await api.getScreenShareToken(
        authToken,
        channelId,
        publish: false,
        publisherUserId: publisherUserId,
        deviceId: _e2eeDeviceId,
        e2eeEpochId: _e2eeEpochId,
      );
      if (requestGeneration != _screenViewerRequestGeneration ||
          !_authorizedScreenSharingUserIds.contains(publisherUserId) ||
          channelId != _channelId) {
        return;
      }
      await _connectScreenRoom(token, expectedPublisherUserId: publisherUserId);
    } catch (error, stackTrace) {
      ClientLog.error('voice.screen.viewer', error, stackTrace);
    }
  }

  Future<VoiceState> restoreRealtimeState() async {
    final generation = _sessionGeneration;
    final api = _api;
    final authToken = _authToken;
    final serverId = _serverId;
    final channelId = _channelId ?? snapshot.voiceState?.channelId;
    if (api == null ||
        authToken == null ||
        serverId == null ||
        channelId == null) {
      throw OpenSpeakException('当前语音会话无法恢复实时状态');
    }
    final state = await _setVoiceStateWhenRealtimeReady(
      api,
      authToken,
      serverId,
      channelId,
      muted: snapshot.muted,
      deafened: snapshot.listenOff,
      speaking: snapshot.speaking,
    );
    if (_isActiveSessionGeneration(generation)) {
      _setSnapshot(snapshot.copyWith(voiceState: state));
    }
    return state;
  }

  void _attachRoomListener(lk.Room room) {
    room.addListener(_refreshRoomSnapshot);
    _roomListener = room.createListener()
      ..on<lk.RoomConnectedEvent>((_) => _handleConnected())
      ..on<lk.RoomReconnectingEvent>((_) => _handleReconnecting('正在重连 LiveKit'))
      ..on<lk.RoomResumingEvent>((_) => _handleReconnecting('正在恢复 LiveKit'))
      ..on<lk.RoomReconnectedEvent>((_) => _handleConnected())
      ..on<lk.RoomDisconnectedEvent>((_) => _handleDisconnected())
      ..on<lk.ParticipantConnectedEvent>((event) {
        _attachRemoteParticipantListener(event.participant);
        _handleRemoteAudioChanged();
      })
      ..on<lk.ParticipantDisconnectedEvent>((event) {
        _detachRemoteParticipantListener(event.participant.sid);
        _handleRemoteAudioChanged();
      })
      ..on<lk.TrackPublishedEvent>((_) => _handleRemoteAudioChanged())
      ..on<lk.TrackUnpublishedEvent>((_) => _handleRemoteAudioChanged())
      ..on<lk.TrackSubscribedEvent>((_) => _handleRemoteAudioChanged())
      ..on<lk.TrackUnsubscribedEvent>((_) => _handleRemoteAudioChanged())
      ..on<lk.TrackMutedEvent>((_) => _handleRemoteAudioChanged())
      ..on<lk.TrackUnmutedEvent>((_) => _handleRemoteAudioChanged())
      ..on<lk.LocalTrackPublishedEvent>((_) {
        unawaited(_handleLocalTrackPublished());
      })
      ..on<lk.LocalTrackUnpublishedEvent>((_) => _handleRemoteAudioChanged())
      ..on<lk.TrackE2EEStateEvent>(_handleE2EEState)
      ..on<lk.ActiveSpeakersChangedEvent>((_) => _handleSpeakingChanged());
  }

  Future<void> _handleLocalTrackPublished() async {
    try {
      final manager = _room?.e2eeManager;
      if (manager != null) {
        await manager.setKeyIndex(_activeE2EEKeyIndex);
      }
    } catch (error, stackTrace) {
      ClientLog.error('voice.e2ee.track_index', error, stackTrace);
    }
    _handleRemoteAudioChanged();
  }

  void _scheduleOldE2EEKeyRetirement(String epochId, int activeIndex) {
    _e2eeOldKeyRetireTimer?.cancel();
    _e2eeOldKeyRetireTimer = Timer(const Duration(seconds: 2), () async {
      if (_e2eeEpochId != epochId || _activeE2EEKeyIndex != activeIndex) {
        return;
      }
      final manager = _room?.e2eeManager;
      final key = _e2eeKey;
      if (manager == null || key == null) return;
      try {
        if (_e2eeParticipantKeys) {
          await _installParticipantKeys(
            manager.keyProvider,
            key,
            _channelMemberUserIds,
            activeIndex,
            mirror: true,
          );
        } else {
          await manager.keyProvider.setRawKey(key, keyIndex: 1 - activeIndex);
        }
        await _screenRoom?.e2eeManager?.keyProvider.setRawKey(
          key,
          keyIndex: 1 - activeIndex,
        );
        ClientLog.write('voice.e2ee', 'old media key retired epoch=$epochId');
      } catch (error, stackTrace) {
        ClientLog.error('voice.e2ee.retire', error, stackTrace);
      } finally {
        _retiringE2EEKey?.fillRange(0, _retiringE2EEKey!.length, 0);
        _retiringE2EEKey = null;
      }
    });
  }

  void _syncRemoteParticipantListeners(lk.Room room) {
    final activeSids = room.remoteParticipants.values
        .map((participant) => participant.sid)
        .toSet();
    for (final sid
        in _remoteParticipantListeners.keys
            .where((sid) => !activeSids.contains(sid))
            .toList()) {
      _detachRemoteParticipantListener(sid);
    }
    for (final participant in room.remoteParticipants.values) {
      _attachRemoteParticipantListener(participant);
    }
  }

  void _attachRemoteParticipantListener(lk.RemoteParticipant participant) {
    if (_remoteParticipantListeners.containsKey(participant.sid)) return;
    _remoteParticipantListeners[participant.sid] = participant.createListener()
      ..on<lk.TrackSubscriptionPermissionChangedEvent>(
        (_) => _handleRemoteAudioChanged(),
      );
  }

  void _detachRemoteParticipantListener(String sid) {
    final listener = _remoteParticipantListeners.remove(sid);
    if (listener != null) unawaited(listener.dispose());
  }

  Future<void> _disposeRemoteParticipantListeners() async {
    final listeners = _remoteParticipantListeners.values.toList();
    _remoteParticipantListeners.clear();
    await Future.wait(listeners.map((listener) => listener.dispose()));
  }

  void _handleE2EEState(lk.TrackE2EEStateEvent event) {
    if (event.state == lk.E2EEState.kNew) {
      return;
    }
    if (event.state == lk.E2EEState.kOk ||
        event.state == lk.E2EEState.kKeyRatcheted) {
      if (snapshot.status == '媒体端到端加密失败') {
        final token = snapshot.voiceToken;
        _setSnapshot(
          snapshot.copyWith(
            status: token == null ? '已连接' : '已连接 ${token.room}',
          ),
        );
      }
      return;
    }
    ClientLog.write(
      'voice.e2ee',
      'state=${event.state.name} participant=${event.participant.identity}',
    );
    _setSnapshot(snapshot.copyWith(status: '媒体端到端加密失败'));
  }

  void _handleConnected() {
    final token = snapshot.voiceToken;
    final room = _room;
    if (room != null) _syncRemoteParticipantListeners(room);
    if (voiceRoomEventShouldFinalizeSession(connecting: snapshot.connecting)) {
      _cancelLiveKitReconnect();
      _reconnectInFlight = false;
      _intentionalLeave = false;
      _setSnapshot(
        snapshot.copyWith(
          connecting: false,
          connected: true,
          reconnecting: false,
          status: token == null ? '已连接' : '已连接 ${token.room}',
        ),
      );
      _microphoneGateOpen = false;
      unawaited(_applyMediaRouting());
    }
    _refreshRoomSnapshot();
  }

  void _handleReconnecting(String status) {
    _setSnapshot(
      snapshot.copyWith(
        connecting: false,
        connected: false,
        reconnecting: true,
        status: status,
      ),
    );
  }

  void _handleDisconnected() {
    if (_room == null) {
      return;
    }
    if (_intentionalLeave) {
      return;
    }
    _microphoneGateOpen = false;
    _setSnapshot(
      snapshot.copyWith(
        connecting: false,
        connected: false,
        reconnecting: true,
        status: 'LiveKit 已断开，准备重连',
        remoteParticipants: 0,
        remoteAudioTracks: 0,
        liveKitParticipantUserIds: const {},
        liveKitSpeakingUserIds: const {},
        remoteAudioBitrate: 0,
        remoteAudioBytesReceived: 0,
        speaking: false,
        clearMediaNetworkStats: true,
      ),
    );
    _scheduleLiveKitReconnect();
  }

  void _handleRemoteAudioChanged() {
    _receiverPacketsReceived.clear();
    _receiverPacketsLost.clear();
    _receiverJitterBufferDelay.clear();
    _receiverJitterBufferEmittedCount.clear();
    unawaited(_applyMediaRouting());
    _refreshRoomSnapshot();
  }

  void _handleSpeakingChanged() {
    _refreshRoomSnapshot();
  }

  void _handleAudioSenderStats(lk.AudioSenderStatsEvent event) {
    final streamId = event.stats.streamId;
    final sent = event.stats.packetsSent ?? 0;
    final lost = math.max<num>(0, event.stats.packetsLost ?? 0);
    final previousSent = _senderPacketsSent[streamId];
    final previousLost = _senderPacketsLost[streamId];
    _senderPacketsSent[streamId] = sent;
    _senderPacketsLost[streamId] = lost;
    if (previousSent == null || previousLost == null) return;
    final sentDelta = packetCounterDelta(sent, previousSent);
    final lostDelta = packetCounterDelta(lost, previousLost);
    _setSnapshot(
      snapshot.copyWith(
        upstreamPacketLoss: _packetLossPercent(
          total: sentDelta + lostDelta,
          lost: lostDelta,
        ),
      ),
    );
  }

  double _packetLossPercent({required num total, required num lost}) {
    final safeTotal = total < 0 ? 0.0 : total.toDouble();
    final safeLost = lost < 0 ? 0.0 : lost.toDouble();
    if (safeTotal <= 0) return 0;
    return (safeLost / safeTotal * 100).clamp(0.0, 100.0).toDouble();
  }

  void _startSpeakingPoll() {
    _speakingPollTimer?.cancel();
    unawaited(_pollAudioActivity());
    _speakingPollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_pollAudioActivity());
    });
  }

  Future<void> _pollAudioActivity() async {
    final room = _room;
    if (room == null || !snapshot.connected || _audioActivityPollInFlight) {
      return;
    }
    _audioActivityPollInFlight = true;
    final participantUserIds = <String>{};
    final speakingUserIds = <String>{};
    final sampledKeys = <String>{};
    var localAudioActive = false;
    var localInputRms = 0.0;
    try {
      final localParticipant = room.localParticipant;
      if (localParticipant != null && localParticipant.identity.isNotEmpty) {
        final identity = localParticipant.identity;
        participantUserIds.add(identity);
        if (_microphoneMonitorTrack == null) {
          for (final publication in localParticipant.audioTrackPublications) {
            final track = publication.track;
            if (track == null) continue;
            final stats = await track.getSenderStats();
            if (stats == null) continue;
            final source = stats.audioSourceStats;
            final key = 'local:$identity:${publication.sid}';
            sampledKeys.add(key);
            final sample = _sampleAudioActivity(
              key,
              level: source?.audioLevel,
              totalEnergy: source?.totalAudioEnergy,
              totalDuration: source?.totalSamplesDuration,
            );
            localInputRms = math.max(localInputRms, sample.rms);
            if (sample.active) localAudioActive = true;
          }
          await _updateMicrophoneThresholdGate(localInputRms);
          final activationActive =
              _microphoneActivationMode ==
                  MicrophoneActivationMode.voiceThreshold
              ? _thresholdGateOpen
              : localAudioActive;
          if (_microphoneGateOpen &&
              (activationActive || localParticipant.isSpeaking)) {
            speakingUserIds.add(identity);
          }
        }
        if (snapshot.speaking) {
          speakingUserIds.add(identity);
        }
      }

      for (final participant in room.remoteParticipants.values) {
        final identity = participant.identity;
        if (identity.isEmpty || !_participantInCurrentChannel(identity)) {
          continue;
        }
        participantUserIds.add(identity);
        var remoteAudioActive = false;
        for (final publication in participant.audioTrackPublications) {
          final track = publication.track;
          if (track == null || !publication.subscribed || publication.muted) {
            continue;
          }
          final stats = await track.getReceiverStats();
          if (stats == null) continue;
          final source = stats.audioSourceStats;
          final key = 'remote:$identity:${publication.sid}';
          sampledKeys.add(key);
          if (_sampleHasAudioActivity(
            key,
            level: source?.audioLevel,
            totalEnergy: source?.totalAudioEnergy ?? stats.totalAudioEnergy,
            totalDuration:
                source?.totalSamplesDuration ?? stats.totalSamplesDuration,
          )) {
            remoteAudioActive = true;
          }
        }
        if (remoteAudioActive || participant.isSpeaking) {
          speakingUserIds.add(identity);
        }
      }

      _audioEnergySamples.removeWhere((key, _) => !sampledKeys.contains(key));
      if (_microphoneMonitorTrack == null) {
        final nextInputLevel = microphoneLevelFromRms(localInputRms);
        if ((microphoneInputLevel.value - nextInputLevel).abs() >= 0.01 ||
            nextInputLevel == 0) {
          microphoneInputLevel.value = nextInputLevel;
        }
        microphoneInputActive.value = localAudioActive;
      }
      if (!setEquals(snapshot.liveKitParticipantUserIds, participantUserIds) ||
          !setEquals(snapshot.liveKitSpeakingUserIds, speakingUserIds)) {
        _setSnapshot(
          snapshot.copyWith(
            liveKitParticipantUserIds: participantUserIds,
            liveKitSpeakingUserIds: speakingUserIds,
          ),
        );
      }
      if (_microphoneMonitorTrack == null) {
        final activationActive =
            _microphoneActivationMode == MicrophoneActivationMode.voiceThreshold
            ? _thresholdGateOpen
            : localAudioActive;
        _setLocalSpeaking(
          activationActive || room.localParticipant?.isSpeaking == true,
        );
      }
    } catch (_) {
      // Audio-level polling is best-effort; LiveKit speaking events remain as
      // a fallback on platforms that omit WebRTC energy statistics.
    } finally {
      _audioActivityPollInFlight = false;
    }
  }

  ({bool active, double rms}) _sampleAudioActivity(
    String key, {
    required num? level,
    required num? totalEnergy,
    required num? totalDuration,
  }) {
    final previous = _audioEnergySamples[key];
    double? intervalRms;
    if (previous?.energy != null &&
        previous?.duration != null &&
        totalEnergy != null &&
        totalDuration != null) {
      final energyDelta = totalEnergy - previous!.energy!;
      final durationDelta = totalDuration - previous.duration!;
      if (energyDelta >= 0 && durationDelta > 0) {
        intervalRms = math.sqrt(energyDelta / durationDelta);
      }
    }
    final reportedLevel = level?.toDouble();
    final observedRms = switch ((reportedLevel, intervalRms)) {
      (final double reported, final double interval) => math.max(
        reported,
        interval,
      ),
      (final double reported, null) => reported,
      (null, final double interval) => interval,
      _ => null,
    };
    if (previous == null) {
      _audioEnergySamples[key] = _AudioEnergySample(
        energy: totalEnergy,
        duration: totalDuration,
        noiseFloorRms: observedRms ?? 0,
      );
      return (active: false, rms: observedRms ?? 0);
    }
    if (observedRms == null) return (active: false, rms: 0);
    final active =
        observedRms >=
        math.max(
          _minimumVoiceAudioRms,
          previous.noiseFloorRms * _noiseFloorMultiplier,
        );
    final nextNoiseFloor = active
        ? previous.noiseFloorRms
        : previous.noiseFloorRms * 0.9 + observedRms * 0.1;
    _audioEnergySamples[key] = _AudioEnergySample(
      energy: totalEnergy ?? previous.energy,
      duration: totalDuration ?? previous.duration,
      noiseFloorRms: nextNoiseFloor,
    );
    return (active: active, rms: observedRms);
  }

  bool _sampleHasAudioActivity(
    String key, {
    required num? level,
    required num? totalEnergy,
    required num? totalDuration,
  }) => _sampleAudioActivity(
    key,
    level: level,
    totalEnergy: totalEnergy,
    totalDuration: totalDuration,
  ).active;

  Future<void> _updateMicrophoneThresholdGate(double rms) async {
    if (_microphoneActivationMode != MicrophoneActivationMode.voiceThreshold) {
      return;
    }
    final now = DateTime.now();
    final above = rms >= microphoneThresholdRms(_microphoneThreshold);
    if (above) {
      _thresholdReleaseAt = now.add(_microphoneThresholdReleaseDelay);
      _scheduleThresholdGateRelease();
      if (_thresholdGateOpen) return;
      _thresholdGateOpen = true;
      await _applyMicrophonePublishing();
      return;
    }

    final releaseAt = _thresholdReleaseAt;
    if (releaseAt != null && now.isBefore(releaseAt)) return;
    await _closeMicrophoneThresholdGate();
  }

  void _scheduleThresholdGateRelease() {
    _thresholdGateReleaseTimer?.cancel();
    final releaseAt = _thresholdReleaseAt;
    if (releaseAt == null) return;
    final delay = releaseAt.difference(DateTime.now());
    _thresholdGateReleaseTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_closeMicrophoneThresholdGateIfDue()),
    );
  }

  Future<void> _closeMicrophoneThresholdGateIfDue() async {
    if (_disposed ||
        _microphoneActivationMode != MicrophoneActivationMode.voiceThreshold) {
      return;
    }
    final releaseAt = _thresholdReleaseAt;
    if (releaseAt != null && DateTime.now().isBefore(releaseAt)) {
      _scheduleThresholdGateRelease();
      return;
    }
    await _closeMicrophoneThresholdGate();
  }

  Future<void> _closeMicrophoneThresholdGate() async {
    _thresholdGateReleaseTimer?.cancel();
    _thresholdGateReleaseTimer = null;
    _thresholdReleaseAt = null;
    if (!_thresholdGateOpen) return;
    _thresholdGateOpen = false;
    await _applyMicrophonePublishing();
    _setLocalSpeaking(false);
  }

  void startServerLatencyMonitor(OpenSpeakApi api) {
    _serverLatencyTimer?.cancel();
    _latencyApi = api;
    _previousLatencyMs = null;
    _latencyJitterMs = 0;
    _setSnapshot(snapshot.copyWith(clearLatencyStats: true));
    unawaited(_updateServerLatency());
    _serverLatencyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_updateServerLatency());
    });
  }

  void stopServerLatencyMonitor() {
    _serverLatencyTimer?.cancel();
    _serverLatencyTimer = null;
    _latencyApi = null;
    _previousLatencyMs = null;
    _latencyJitterMs = 0;
    _setSnapshot(snapshot.copyWith(clearLatencyStats: true));
  }

  void _startAudioStatsPoll() {
    _audioStatsTimer?.cancel();
    unawaited(_pollAudioTrackStats());
    _audioStatsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollAudioTrackStats());
    });
  }

  void _recordLatency(double latencyMs) {
    final previous = _previousLatencyMs;
    if (previous != null) {
      final difference = (latencyMs - previous).abs();
      _latencyJitterMs += (difference - _latencyJitterMs) / 16;
    }
    _previousLatencyMs = latencyMs;
    _setSnapshot(
      snapshot.copyWith(
        latencyMs: latencyMs,
        latencyJitterMs: _latencyJitterMs,
      ),
    );
  }

  Future<void> _updateServerLatency() async {
    final api = _latencyApi;
    if (api == null || _latencyMeasurementInFlight || _disposed) {
      return;
    }
    _latencyMeasurementInFlight = true;
    try {
      final latencyMs = await api.measureLatencyMs();
      if (_disposed || !identical(_latencyApi, api)) return;
      _recordLatency(latencyMs);
    } catch (_) {
      // Keep the last successful sample through brief API/network failures.
    } finally {
      _latencyMeasurementInFlight = false;
    }
  }

  void _setLocalSpeaking(bool value) {
    final nextSpeaking = value && _shouldReportSpeaking();
    final nextSpeakingUserIds = withLocalSpeakingState(
      snapshot.liveKitSpeakingUserIds,
      localUserId: _room?.localParticipant?.identity,
      speaking: nextSpeaking,
    );
    if (nextSpeaking == snapshot.speaking &&
        setEquals(nextSpeakingUserIds, snapshot.liveKitSpeakingUserIds)) {
      return;
    }
    _setSnapshot(
      snapshot.copyWith(
        speaking: nextSpeaking,
        liveKitSpeakingUserIds: nextSpeakingUserIds,
      ),
    );
    _speakingSyncTimer?.cancel();
    if (nextSpeaking) {
      unawaited(_syncVoiceState());
    } else {
      _speakingSyncTimer = Timer(const Duration(milliseconds: 200), () {
        unawaited(_syncVoiceState());
      });
    }
  }

  void _refreshRoomSnapshot() {
    final room = _room;
    if (room == null) return;
    final remoteAudioTracks = _remoteAudioTracks(room).length;
    final participantUserIds = <String>{};
    final localParticipant = room.localParticipant;
    if (localParticipant != null && localParticipant.identity.isNotEmpty) {
      participantUserIds.add(localParticipant.identity);
    }
    for (final participant in room.remoteParticipants.values) {
      if (participant.identity.isEmpty ||
          !_participantInCurrentChannel(participant.identity)) {
        continue;
      }
      participantUserIds.add(participant.identity);
    }
    final speakingUserIds = withLocalSpeakingState(
      snapshot.liveKitSpeakingUserIds.where(participantUserIds.contains),
      localUserId: localParticipant?.identity,
      speaking:
          snapshot.speaking ||
          (localParticipant?.isSpeaking == true && _shouldReportSpeaking()),
    );
    for (final participant in room.remoteParticipants.values) {
      if (participant.identity.isEmpty ||
          !_participantInCurrentChannel(participant.identity)) {
        continue;
      }
      if (participant.isSpeaking) speakingUserIds.add(participant.identity);
    }
    final currentChannelRemoteParticipants = _currentChannelRemoteParticipants(
      room,
    );
    _setSnapshot(
      snapshot.copyWith(
        remoteParticipants: currentChannelRemoteParticipants.length,
        remoteAudioTracks: remoteAudioTracks,
        liveKitParticipantUserIds: participantUserIds,
        liveKitSpeakingUserIds: speakingUserIds,
      ),
    );
    if (_microphoneMonitorTrack == null) {
      _setLocalSpeaking(room.localParticipant?.isSpeaking == true);
    }
  }

  Future<void> _pollAudioTrackStats() async {
    final room = _room;
    if (room == null ||
        !snapshot.connected ||
        _audioStatsPollInFlight ||
        _disposed) {
      return;
    }
    _audioStatsPollInFlight = true;
    try {
      final localParticipant = room.localParticipant;
      if (localParticipant != null) {
        for (final publication in localParticipant.audioTrackPublications) {
          final track = publication.track;
          if (track == null) continue;
          final stats = await track.getSenderStats();
          if (stats != null) {
            _handleAudioSenderStats(
              lk.AudioSenderStatsEvent(stats: stats, currentBitrate: 0),
            );
          }
        }
      }
      var receivedDelta = 0.0;
      var lostDelta = 0.0;
      num remoteBitrate = 0;
      var remoteBytesReceived = 0;
      var hasPacketInterval = false;
      final sampledStreamIds = <String>{};
      final remoteTracks = _remoteAudioTracks(room);
      for (final track in remoteTracks) {
        final stats = await track.getReceiverStats();
        if (stats == null) continue;
        final streamId = stats.streamId;
        sampledStreamIds.add(streamId);
        final received = stats.packetsReceived ?? 0;
        final lost = math.max<num>(0, stats.packetsLost ?? 0);
        final previousReceived = _receiverPacketsReceived[streamId];
        final previousLost = _receiverPacketsLost[streamId];
        if (previousReceived != null && previousLost != null) {
          hasPacketInterval = true;
          receivedDelta += packetCounterDelta(received, previousReceived);
          lostDelta += packetCounterDelta(lost, previousLost);
        }
        _receiverPacketsReceived[streamId] = received;
        _receiverPacketsLost[streamId] = lost;
        if (kIsWeb && track.receiver != null) {
          final rawStats = await track.receiver!.getStats();
          for (final report in rawStats) {
            if (report.type != 'inbound-rtp') continue;
            final delay = report.values['jitterBufferDelay'];
            final count = report.values['jitterBufferEmittedCount'];
            if (delay is! num || count is! num) break;
            final average = counterAverageDelta(
              total: delay,
              previousTotal: _receiverJitterBufferDelay[streamId],
              count: count,
              previousCount: _receiverJitterBufferEmittedCount[streamId],
            );
            _receiverJitterBufferDelay[streamId] = delay;
            _receiverJitterBufferEmittedCount[streamId] = count;
            if (average != null) {
              ClientLog.write(
                'voice.audio.stats',
                'stream=$streamId '
                    'jitter_buffer_ms=${(average * 1000).toStringAsFixed(1)} '
                    'jitter_ms=${stats.jitter == null ? 'unknown' : (stats.jitter! * 1000).toStringAsFixed(1)}',
              );
            }
            break;
          }
        }
        remoteBitrate += track.currentBitrate ?? 0;
        remoteBytesReceived += stats.bytesReceived?.round() ?? 0;
      }
      _receiverPacketsReceived.removeWhere(
        (streamId, _) => !sampledStreamIds.contains(streamId),
      );
      _receiverPacketsLost.removeWhere(
        (streamId, _) => !sampledStreamIds.contains(streamId),
      );
      _receiverJitterBufferDelay.removeWhere(
        (streamId, _) => !sampledStreamIds.contains(streamId),
      );
      _receiverJitterBufferEmittedCount.removeWhere(
        (streamId, _) => !sampledStreamIds.contains(streamId),
      );
      if (remoteTracks.isEmpty) {
        _setSnapshot(
          snapshot.copyWith(
            remoteAudioBitrate: 0,
            remoteAudioBytesReceived: 0,
            downstreamPacketLoss: 0.0,
          ),
        );
      } else if (sampledStreamIds.isNotEmpty) {
        _setSnapshot(
          snapshot.copyWith(
            remoteAudioBitrate: remoteBitrate,
            remoteAudioBytesReceived: remoteBytesReceived,
            downstreamPacketLoss: hasPacketInterval
                ? _packetLossPercent(
                    total: receivedDelta + lostDelta,
                    lost: lostDelta,
                  )
                : snapshot.downstreamPacketLoss,
          ),
        );
      }
    } catch (_) {
      // Desktop WebRTC drivers can briefly reject stats during track changes.
    } finally {
      _audioStatsPollInFlight = false;
    }
  }

  Future<void> _applyMediaRouting() {
    final queued = _mediaRoutingTail.then((_) => _applyMediaRoutingOnce());
    _mediaRoutingTail = queued.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      ClientLog.error('voice.routing', error, stackTrace);
    });
    return queued;
  }

  Future<void> _applyMediaRoutingOnce() async {
    _applyTrackSubscriptionPermissions();
    await _applyListenOffToRoom();
    await _applyScreenShareSubscriptions();
    await _applyMicrophonePublishing();
  }

  void _applyTrackSubscriptionPermissions() {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    if (!usesPersistentRoom) {
      participant.setTrackSubscriptionPermissions(allParticipantsAllowed: true);
      return;
    }
    final localUserId = participant.identity;
    participant.setTrackSubscriptionPermissions(
      allParticipantsAllowed: false,
      trackPermissions: [
        for (final userId in _channelMemberUserIds)
          if (userId.isNotEmpty && userId != localUserId)
            lk.ParticipantTrackPermission(userId, true, null),
      ],
    );
  }

  Future<void> _applyScreenShareSubscriptions() async {
    final room = _screenRoom;
    if (room == null) return;
    final e2eeRequired = _screenToken?.e2eeRequired == true;
    for (final participant in room.remoteParticipants.values) {
      final shouldSubscribe =
          participant.identity == _expectedScreenPublisherUserId &&
          _authorizedScreenSharingUserIds.contains(participant.identity);
      for (final publication in participant.videoTrackPublications) {
        if (publication.source != lk.TrackSource.screenShareVideo) continue;
        try {
          if (!shouldSubscribe ||
              !voiceTrackEncryptionAccepted(
                e2eeRequired: e2eeRequired,
                encryptionType: publication.encryptionType,
              )) {
            await publication.unsubscribe();
            if (shouldSubscribe) {
              ClientLog.write(
                'voice.e2ee',
                'rejected unencrypted screen '
                    'participant=${participant.identity}',
              );
              _setSnapshot(snapshot.copyWith(status: '已拒绝未加密的远端媒体'));
            }
            continue;
          }
          if (!publication.subscribed) await publication.subscribe();
        } catch (error, stackTrace) {
          // 发布者的 LiveKit 订阅权限可能比频道状态稍晚到达。
          // 保持未订阅，等权限变更事件再重试。
          ClientLog.error('voice.screen.routing', error, stackTrace);
        }
      }
    }
    _refreshScreenRoom();
  }

  bool _shouldKeepMicrophoneTrack() => voiceShouldKeepMicrophoneTrack(
    canPublish: snapshot.voiceToken?.canPublish != false,
    listenOff: snapshot.listenOff,
    microphoneUnavailable: _webMicrophoneUnavailable,
  );

  bool _shouldOpenMicrophoneGate() {
    return _shouldKeepMicrophoneTrack() &&
        !snapshot.muted &&
        microphoneActivationGateOpen(
          mode: _microphoneActivationMode,
          pushToTalkPressed: _pushToTalkPressed,
          thresholdOpen: _thresholdGateOpen,
        );
  }

  bool _shouldReportSpeaking() {
    final room = _room;
    return room != null && _microphoneGateOpen && _shouldOpenMicrophoneGate();
  }

  Future<void> _applyMicrophonePublishing() {
    _microphoneRoutingRevision += 1;
    final shouldOpenGate = _room != null && _shouldOpenMicrophoneGate();
    _microphoneGateOpen = shouldOpenGate;
    if (!shouldOpenGate) {
      _localAudioActive = false;
      microphoneInputActive.value = false;
      if (!_shouldKeepMicrophoneTrack()) microphoneInputLevel.value = 0;
      _setLocalSpeaking(false);
    }
    return _enqueueMicrophoneOperation(_applyMicrophonePublishingOnce);
  }

  Future<void> _enqueueMicrophoneOperation(Future<void> Function() operation) {
    final queued = _microphoneRoutingTail.then((_) => operation());
    _microphoneRoutingTail = queued.catchError((_) {});
    return queued;
  }

  Future<void> _applyMicrophonePublishingOnce() async {
    final room = _room;
    if (room == null || !_canRouteMicrophoneSender(room)) return;
    final shouldKeepTrack = _shouldKeepMicrophoneTrack();
    var publication = room.localParticipant?.getTrackPublicationBySource(
      lk.TrackSource.microphone,
    );
    if (!shouldKeepTrack) {
      _microphoneCaptureRestartPending = false;
      if (publication != null) {
        await room.localParticipant?.removePublishedTrack(publication.sid);
      }
      await _releaseMicrophoneCapture();
      return;
    }
    var track = await _ensureMicrophoneCapture(room);
    if (track == null) return;
    publication = room.localParticipant?.getTrackPublicationBySource(
      lk.TrackSource.microphone,
    );
    if (publication == null) {
      ClientLog.write('voice.mic', 'publication create start');
      if (windowsMicrophoneLevelSupported(
        defaultTargetPlatform,
        isWeb: kIsWeb,
      )) {
        await _releaseMicrophoneMonitor();
      }
      track.mediaStreamTrack.enabled = false;
      try {
        publication = await room.localParticipant?.publishAudioTrack(track);
      } finally {
        publication = room.localParticipant?.getTrackPublicationBySource(
          lk.TrackSource.microphone,
        );
        try {
          if (publication?.track case final lk.LocalAudioTrack publishedTrack) {
            final shouldTransmit = _shouldTransmitMicrophone(room);
            await _replaceMicrophoneSenderTrack(
              publishedTrack,
              await _microphoneSenderTrack(
                publishedTrack,
                shouldTransmit: shouldTransmit,
              ),
            );
          }
        } finally {
          track.mediaStreamTrack.enabled = true;
        }
      }
      _microphoneCaptureRestartPending = false;
      ClientLog.write('voice.mic', 'publication create done');
    }
    if (publication != null &&
        !voiceTrackEncryptionAccepted(
          e2eeRequired: snapshot.voiceToken?.e2eeRequired == true,
          encryptionType: publication.encryptionType,
        )) {
      ClientLog.write('voice.e2ee', 'local microphone is not GCM encrypted');
      _setSnapshot(snapshot.copyWith(status: '本机媒体端到端加密失败'));
    }
    var shouldTransmit = _shouldTransmitMicrophone(room);
    if (publication != null && !identical(_room, room)) {
      await room.localParticipant?.removePublishedTrack(publication.sid);
    } else if (publication?.track
        case final lk.LocalAudioTrack publishedTrack) {
      var forceSenderAttach = false;
      if (microphoneCaptureRestartShouldRun(
        restartPending: _microphoneCaptureRestartPending,
        shouldTransmit: _shouldTransmitMicrophone(room),
      )) {
        forceSenderAttach = microphoneCaptureRestartShouldDetachSender(
          defaultTargetPlatform,
          isWeb: kIsWeb,
        );
        if (forceSenderAttach) {
          await _replaceMicrophoneSenderTrack(publishedTrack, null);
        }
        await _releaseMicrophoneMonitor();
        await _releaseWebMicrophoneSenderTrack();
        ClientLog.write('voice.mic', 'published capture restart start');
        await publishedTrack.restartTrack(_audioCaptureOptions);
        publishedTrack.mediaStreamTrack.onEnded = null;
        _microphoneCaptureTrack = publishedTrack;
        _microphoneCaptureRestartPending = false;
        track = publishedTrack;
        ClientLog.write('voice.mic', 'published capture restart done');
      }
      // LiveKit disposes the track when a publication is removed, even with
      // stopLocalTrackOnUnpublish disabled. Keep the publication and detach
      // only its sender so local PCM monitoring survives while alone.
      while (true) {
        final revision = _microphoneRoutingRevision;
        shouldTransmit = _shouldTransmitMicrophone(room);
        if (shouldTransmit) {
          await _syncMicrophoneMonitor(
            track,
            windowsUseWebRtc: windowsMicrophoneLevelUsesWebRtc(
              fastConnecting: false,
              transmitting: true,
            ),
          );
          if (revision != _microphoneRoutingRevision) continue;
        }
        await _replaceMicrophoneSenderTrack(
          publishedTrack,
          await _microphoneSenderTrack(track, shouldTransmit: shouldTransmit),
          force: forceSenderAttach && shouldTransmit,
        );
        forceSenderAttach = false;
        await _syncMicrophoneMonitor(
          track,
          windowsUseWebRtc: windowsMicrophoneLevelUsesWebRtc(
            fastConnecting: false,
            transmitting: shouldTransmit,
          ),
        );
        if (revision == _microphoneRoutingRevision) break;
      }
      track.mediaStreamTrack.enabled = true;
    }
  }

  Future<lk.LocalAudioTrack?> _ensureMicrophoneCapture(lk.Room room) async {
    var track = _microphoneCaptureTrack;
    if (track == null) {
      await _releaseMicrophonePreview?.call();
      ClientLog.write('voice.mic', 'capture create start');
      track = await lk.LocalAudioTrack.create(_audioCaptureOptions);
      ClientLog.write('voice.mic', 'capture create done');
      // Device hotplug is handled by AudioDeviceMonitor. Keep the publication
      // stable instead of letting LiveKit unpublish and renegotiate on track end.
      track.mediaStreamTrack.onEnded = null;
      if (!identical(_room, room) || !_shouldKeepMicrophoneTrack()) {
        await track.stop();
        return null;
      }
      _microphoneCaptureTrack = track;
    }
    return identical(_room, room) ? track : null;
  }

  bool _shouldTransmitMicrophone(lk.Room room) {
    final publication = room.localParticipant?.getTrackPublicationBySource(
      lk.TrackSource.microphone,
    );
    final encryptionAccepted = publication == null
        ? snapshot.voiceToken?.e2eeRequired != true
        : voiceTrackEncryptionAccepted(
            e2eeRequired: snapshot.voiceToken?.e2eeRequired == true,
            encryptionType: publication.encryptionType,
          );
    return identical(_room, room) &&
        _e2eeMediaActive &&
        encryptionAccepted &&
        microphoneAudioShouldTransmit(
          activationOpen: _shouldOpenMicrophoneGate(),
          hasRemoteParticipants: _currentChannelRemoteParticipants(
            room,
          ).isNotEmpty,
        );
  }

  bool _canRouteMicrophoneSender(lk.Room room) =>
      identical(_room, room) &&
      microphoneSenderRoutingAllowed(
        reconnecting: snapshot.reconnecting,
        roomConnected: room.connectionState == lk.ConnectionState.connected,
        roomConnecting: identical(_connectingRoom, room),
      );

  Future<rtc.MediaStreamTrack?> _microphoneSenderTrack(
    lk.LocalAudioTrack track, {
    required bool shouldTransmit,
  }) async {
    if (!microphoneSenderShouldStayAttached(
      isWeb: kIsWeb,
      shouldTransmit: shouldTransmit,
    )) {
      return null;
    }
    if (!kIsWeb) return track.mediaStreamTrack;
    var senderTrack = _webMicrophoneSenderTrack;
    if (senderTrack == null) {
      senderTrack = await track.mediaStreamTrack.clone();
      if (!identical(_microphoneCaptureTrack, track)) {
        await senderTrack.stop();
        return null;
      }
      _webMicrophoneSenderTrack = senderTrack;
    }
    senderTrack.enabled = shouldTransmit;
    return senderTrack;
  }

  Future<void> _replaceMicrophoneSenderTrack(
    lk.LocalAudioTrack track,
    rtc.MediaStreamTrack? next, {
    bool force = false,
  }) async {
    final room = _room;
    if (room == null || !_canRouteMicrophoneSender(room)) return;
    final sender = track.sender;
    if (sender == null) return;
    final current = sender.track;
    final alreadyAttached =
        identical(current, next) ||
        (current == null && next == null) ||
        (current?.id != null && current?.id == next?.id);
    if (!microphoneSenderReplacementShouldRun(
      force: force,
      alreadyAttached: alreadyAttached,
    )) {
      return;
    }
    ClientLog.write(
      'voice.mic',
      'sender ${next == null ? 'detach' : 'attach'} start',
    );
    try {
      await sender.replaceTrack(next);
    } catch (error) {
      if (!_canRouteMicrophoneSender(room)) {
        ClientLog.write('voice.mic', 'sender route deferred until reconnect');
        return;
      }
      rethrow;
    }
    ClientLog.write(
      'voice.mic',
      'sender ${next == null ? 'detach' : 'attach'} done',
    );
  }

  Future<void> _syncMicrophoneMonitor(
    lk.LocalAudioTrack? track, {
    bool windowsUseWebRtc = false,
  }) async {
    final pcmSupported = microphonePcmMonitorSupported(
      defaultTargetPlatform,
      isWeb: kIsWeb,
    );
    final windowsLevelSupported = windowsMicrophoneLevelSupported(
      defaultTargetPlatform,
      isWeb: kIsWeb,
    );
    if (track is! lk.LocalAudioTrack ||
        (!pcmSupported && !windowsLevelSupported)) {
      await _releaseMicrophoneMonitor();
      return;
    }
    if (identical(_microphoneMonitorTrack, track) &&
        (!windowsLevelSupported ||
            _windowsMonitorUsesWebRtc == windowsUseWebRtc)) {
      return;
    }
    await _releaseMicrophoneMonitor();
    if (windowsLevelSupported) {
      _microphoneMonitorTrack = track;
      _windowsMonitorUsesWebRtc = windowsUseWebRtc;
      final resolvedDeviceId = resolvedMicrophoneTrackDeviceId(
        track,
        fallback: _audioInputDeviceId,
      );
      final started = await _windowsMicrophoneLevelMonitor.start(
        deviceId: resolvedDeviceId,
        trackId: track.mediaStreamTrack.id,
        useWebRtc: windowsUseWebRtc,
        onRms: (rms) {
          if (identical(_microphoneMonitorTrack, track)) {
            _windowsMicrophoneLevelIdleTimer?.cancel();
            if (windowsUseWebRtc) {
              _windowsMicrophoneLevelIdleTimer = Timer(
                _windowsWebRtcLevelIdleDelay,
                () {
                  if (identical(_microphoneMonitorTrack, track) &&
                      _windowsMonitorUsesWebRtc == true) {
                    _handleLocalMicrophoneRms(0);
                  }
                },
              );
            }
            _handleLocalMicrophoneRms(rms);
          }
        },
      );
      if (!started) {
        if (identical(_microphoneMonitorTrack, track)) {
          _microphoneMonitorTrack = null;
          _windowsMonitorUsesWebRtc = null;
        }
        ClientLog.write(
          'voice.mic',
          'Windows ${windowsUseWebRtc ? 'WebRTC' : 'WASAPI'} '
              'level monitor unavailable',
        );
        return;
      }
      ClientLog.write(
        'voice.mic',
        'Windows ${windowsUseWebRtc ? 'WebRTC' : 'WASAPI'} '
            'event level monitor ready '
            'input=${resolvedDeviceId ?? 'system'}',
      );
      return;
    }
    _microphoneMonitorTrack = track;
    _removeMicrophoneMonitor = track.addAudioRenderer(
      options: const lk.AudioRendererOptions(
        sampleRate: 24000,
        channels: 1,
        format: lk.AudioFormat.Int16,
      ),
      onFrame: (frame) {
        if (!identical(_microphoneMonitorTrack, track)) return;
        _handleLocalMicrophoneRms(microphonePcmRms(frame));
      },
    );
  }

  void _handleLocalMicrophoneRms(double rms) {
    final level = microphoneLevelFromRms(rms);
    if ((microphoneInputLevel.value - level).abs() >= 0.01 || level == 0) {
      microphoneInputLevel.value = level;
    }
    _localAudioActive =
        windowsMicrophoneLevelSupported(defaultTargetPlatform, isWeb: kIsWeb)
        ? _windowsActivityDetector.update(rms)
        : microphoneRmsIndicatesActivity(rms);
    microphoneInputActive.value = _localAudioActive;
    unawaited(_updateMicrophoneThresholdGate(rms));
    _setLocalSpeaking(switch (_microphoneActivationMode) {
      MicrophoneActivationMode.pushToTalk =>
        _pushToTalkPressed && _localAudioActive,
      MicrophoneActivationMode.continuous => _localAudioActive,
      MicrophoneActivationMode.voiceThreshold => _thresholdGateOpen,
    });
  }

  Future<void> _releaseMicrophoneMonitor() async {
    final remove = _removeMicrophoneMonitor;
    _removeMicrophoneMonitor = null;
    _microphoneMonitorTrack = null;
    _windowsMonitorUsesWebRtc = null;
    _windowsMicrophoneLevelIdleTimer?.cancel();
    _windowsMicrophoneLevelIdleTimer = null;
    _localAudioActive = false;
    if (!_disposed) microphoneInputActive.value = false;
    _windowsActivityDetector.reset();
    await _windowsMicrophoneLevelMonitor.stop();
    if (remove != null) {
      ClientLog.write('voice.mic', 'monitor stop start');
      await remove();
      ClientLog.write('voice.mic', 'monitor stop done');
    }
  }

  Future<void> _releaseMicrophoneCapture() async {
    final track = _microphoneCaptureTrack;
    _microphoneCaptureTrack = null;
    await _releaseMicrophoneMonitor();
    await _releaseWebMicrophoneSenderTrack();
    track?.mediaStreamTrack.onEnded = null;
    if (track != null) {
      ClientLog.write('voice.mic', 'capture stop start');
      await track.stop();
      ClientLog.write('voice.mic', 'capture stop done');
    }
  }

  Future<void> _releaseWebMicrophoneSenderTrack() async {
    final track = _webMicrophoneSenderTrack;
    _webMicrophoneSenderTrack = null;
    await track?.stop();
  }

  Future<void> _resetMicrophoneCapture() {
    _microphoneRoutingRevision += 1;
    return _enqueueMicrophoneOperation(() async {
      final publication = _room?.localParticipant?.getTrackPublicationBySource(
        lk.TrackSource.microphone,
      );
      ClientLog.write(
        'voice.mic',
        'reset start senderAttached=${publication?.track is lk.LocalAudioTrack && (publication!.track as lk.LocalAudioTrack).sender?.track != null}',
      );
      if (publication?.track case final lk.LocalAudioTrack publishedTrack) {
        if (identical(_microphoneCaptureTrack, publishedTrack)) {
          await _releaseMicrophoneMonitor();
        } else {
          await _releaseMicrophoneCapture();
        }
        _microphoneCaptureTrack = publishedTrack;
        _microphoneCaptureRestartPending = true;
        ClientLog.write('voice.mic', 'reset deferred to send gate');
        return;
      }
      _microphoneCaptureRestartPending = false;
      await _releaseMicrophoneCapture();
      ClientLog.write('voice.mic', 'reset done');
    });
  }

  lk.AudioCaptureOptions get _audioCaptureOptions => voiceAudioCaptureOptions(
    noiseSuppressionEnabled: _noiseSuppressionEnabled,
    deviceId: _audioInputDeviceId,
  );

  Future<void> _applyAudioDevices() async {
    final inputDeviceId = _audioInputDeviceId;
    final outputDeviceId = _audioOutputDeviceId;
    if (inputDeviceId != null && inputDeviceId.isNotEmpty) {
      try {
        await rtc.Helper.selectAudioInput(inputDeviceId);
      } catch (_) {
        // Device switching support varies by platform and device driver.
      }
    }
    if (outputDeviceId != null && outputDeviceId.isNotEmpty) {
      try {
        await rtc.Helper.selectAudioOutput(outputDeviceId);
      } catch (_) {
        // Keep playback on the system default if explicit routing fails.
      }
    }
  }

  Future<void> _applyListenOffToRoom() async {
    final room = _room;
    if (room == null) return;
    for (final publication in _remoteAudioPublications(
      room,
      currentChannelOnly: false,
    )) {
      await _setRemoteAudioSubscription(
        publication,
        subscribed:
            !snapshot.listenOff &&
            _e2eeMediaActive &&
            _participantInCurrentChannel(publication.participant.identity),
      );
    }
    if (snapshot.listenOff) {
      _setSnapshot(
        snapshot.copyWith(remoteAudioBitrate: 0, remoteAudioBytesReceived: 0),
      );
    }
    _refreshRoomSnapshot();
  }

  Future<void> _setRemoteAudioSubscription(
    lk.RemoteTrackPublication<lk.RemoteAudioTrack> publication, {
    required bool subscribed,
  }) async {
    try {
      final track = publication.track;
      if (subscribed &&
          !voiceTrackEncryptionAccepted(
            e2eeRequired: snapshot.voiceToken?.e2eeRequired == true,
            encryptionType: publication.encryptionType,
          )) {
        if (track != null) {
          await rtc.Helper.setVolume(0, track.mediaStreamTrack);
          await track.disable();
        }
        await publication.unsubscribe();
        ClientLog.write(
          'voice.e2ee',
          'rejected unencrypted track '
              'participant=${publication.participant.identity}',
        );
        _setSnapshot(snapshot.copyWith(status: '已拒绝未加密的远端媒体'));
        return;
      }
      if (subscribed) {
        await publication.subscribe();
        final track = publication.track;
        if (track == null) return;
        await track.enable();
        await rtc.Helper.setVolume(
          _effectiveVolumeForParticipant(publication.participant.identity),
          track.mediaStreamTrack,
        );
      } else {
        if (track != null) {
          await rtc.Helper.setVolume(0, track.mediaStreamTrack);
          await track.disable();
          await track.stop();
        }
        await publication.unsubscribe();
      }
    } catch (error, stackTrace) {
      // 权限收紧时上面已先在本地静音；权限放开时等 LiveKit
      // 权限变更事件触发下一次订阅，不让短暂竞态中断切频道。
      ClientLog.error('voice.audio.routing', error, stackTrace);
    }
  }

  List<lk.RemoteTrackPublication<lk.RemoteAudioTrack>> _remoteAudioPublications(
    lk.Room room, {
    bool currentChannelOnly = true,
  }) {
    final publications = <lk.RemoteTrackPublication<lk.RemoteAudioTrack>>[];
    for (final participant in room.remoteParticipants.values) {
      if (currentChannelOnly &&
          !_participantInCurrentChannel(participant.identity)) {
        continue;
      }
      publications.addAll(participant.audioTrackPublications);
    }
    return publications;
  }

  bool _participantInCurrentChannel(String userId) =>
      voiceParticipantInCurrentChannel(
        persistentRoom: usesPersistentRoom,
        channelMemberUserIds: _channelMemberUserIds,
        userId: userId,
      );

  List<lk.RemoteParticipant> _currentChannelRemoteParticipants(lk.Room room) =>
      room.remoteParticipants.values
          .where(
            (participant) => _participantInCurrentChannel(participant.identity),
          )
          .toList();

  List<lk.RemoteAudioTrack> _remoteAudioTracks(lk.Room room) {
    final tracks = <lk.RemoteAudioTrack>[];
    for (final publication in _remoteAudioPublications(room)) {
      if (!publication.subscribed) continue;
      final track = publication.track;
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  Future<void> _applyOutputVolumeToRoom() async {
    final room = _room;
    if (room == null || snapshot.listenOff) return;
    for (final publication in _remoteAudioPublications(room)) {
      final track = publication.track;
      if (!publication.subscribed || track == null) continue;
      await rtc.Helper.setVolume(
        _effectiveVolumeForParticipant(publication.participant.identity),
        track.mediaStreamTrack,
      );
    }
  }

  double _effectiveVolumeForParticipant(String userId) =>
      effectiveParticipantOutputVolume(
        _outputVolume,
        _participantOutputVolumes[userId] ?? 1.0,
      );

  void _scheduleLiveKitReconnect() {
    if (_disposed || _intentionalLeave) {
      return;
    }
    final api = _api;
    final authToken = _authToken;
    final serverId = _serverId;
    final channelId = _channelId ?? snapshot.voiceState?.channelId;
    if (api == null ||
        authToken == null ||
        serverId == null ||
        channelId == null ||
        snapshot.voiceToken == null) {
      return;
    }
    _liveKitReconnectTimer?.cancel();
    final delay = liveKitReconnectDelay(_liveKitReconnectAttempts);
    _liveKitReconnectAttempts += 1;
    _liveKitReconnectTimer = Timer(delay, () {
      if (_disposed || _intentionalLeave || _reconnectInFlight) {
        return;
      }
      _reconnectInFlight = true;
      unawaited(
        join(
              api: api,
              authToken: authToken,
              serverId: serverId,
              channelId: channelId,
              channelMemberUserIds: _channelMemberUserIds,
              e2eeKey: _e2eeKey,
              e2eeDeviceId: _e2eeDeviceId,
              e2eeEpochId: _e2eeEpochId,
              reconnectAttempt: true,
            )
            .catchError((_) {
              // join() updates the snapshot and schedules the next retry.
            })
            .whenComplete(() {
              _reconnectInFlight = false;
            }),
      );
    });
  }

  void _cancelLiveKitReconnect({bool resetAttempts = false}) {
    _liveKitReconnectTimer?.cancel();
    _liveKitReconnectTimer = null;
    if (resetAttempts) {
      _liveKitReconnectAttempts = 0;
    }
  }

  Future<void> _syncVoiceState({bool throwOnError = false}) async {
    final api = _api;
    final authToken = _authToken;
    final serverId = _serverId;
    final channelId = _channelId ?? snapshot.voiceState?.channelId;
    if (api == null ||
        authToken == null ||
        serverId == null ||
        channelId == null) {
      return;
    }
    if (snapshot.voiceState == null &&
        !snapshot.connected &&
        !snapshot.reconnecting) {
      return;
    }
    try {
      final state = await api.setVoiceState(
        authToken,
        serverId,
        channelId,
        muted: snapshot.muted,
        deafened: snapshot.listenOff,
        speaking: snapshot.speaking,
        screenSharing: isScreenSharing,
        screenShareResolution: _screenShareQuality?.resolution ?? '',
        screenShareFPS: _screenShareQuality?.fps ?? 0,
        screenShareMediaNodeId: _screenToken?.mediaNodeId ?? '',
      );
      _setSnapshot(snapshot.copyWith(voiceState: state));
      if (isScreenSharing && !state.screenSharing) {
        throw OpenSpeakException('服务器拒绝了当前屏幕共享档位');
      }
    } catch (_) {
      if (throwOnError) rethrow;
      // Voice state sync is best-effort; the UI keeps the local media state.
    }
  }

  Future<void> _disposeRoom() async {
    final room = _room;
    _room = null;
    final routingDone = Future.wait([
      _mediaRoutingTail,
      _microphoneRoutingTail,
    ]);
    _microphoneCaptureRestartPending = false;
    _microphoneGateOpen = false;
    _thresholdGateReleaseTimer?.cancel();
    _thresholdGateReleaseTimer = null;
    _thresholdGateOpen = false;
    _thresholdReleaseAt = null;
    microphoneInputLevel.value = 0;
    microphoneInputActive.value = false;
    final listener = _roomListener;
    _roomListener = null;
    await _disposeRemoteParticipantListeners();
    await listener?.dispose();
    _receiverPacketsReceived.clear();
    _receiverPacketsLost.clear();
    _receiverJitterBufferDelay.clear();
    _receiverJitterBufferEmittedCount.clear();
    _senderPacketsSent.clear();
    _senderPacketsLost.clear();
    _audioEnergySamples.clear();
    if (room == null) {
      await routingDone;
    } else {
      await _disposeSpecificRoom(room, routingDone: routingDone);
    }
    await _releaseMicrophoneCapture();
  }

  Future<void> _disposeSpecificRoom(
    lk.Room room, {
    Future<void>? routingDone,
  }) async {
    room.removeListener(_refreshRoomSnapshot);
    await closeVoiceRoom(
      sendLeave: () async {
        // Room.disconnect waits up to ten seconds. Send its leave signal, then
        // keep the existing fast local cleanup used by channel switching.
        // ignore: invalid_use_of_internal_member
        await room.engine.disconnect();
      },
      dispose: room.dispose,
      routingDone: routingDone,
    );
  }

  void _clearE2EEKey() {
    _e2eeOldKeyRetireTimer?.cancel();
    _e2eeOldKeyRetireTimer = null;
    _e2eeKey?.fillRange(0, _e2eeKey!.length, 0);
    _e2eeKey = null;
    _retiringE2EEKey?.fillRange(0, _retiringE2EEKey!.length, 0);
    _retiringE2EEKey = null;
    _e2eeParticipantKeys = false;
    _e2eeDeviceId = '';
    _e2eeEpochId = '';
    _activeE2EEKeyIndex = 0;
    _stagedE2EEKeyIndex = null;
    _e2eeMediaActive = true;
  }

  bool _isActiveSessionGeneration(int generation) {
    return !_disposed && generation == _sessionGeneration;
  }

  void _setSnapshot(VoiceSessionSnapshot next, {bool notify = true}) {
    snapshot = next;
    if (!_disposed && notify) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _intentionalLeave = true;
    _cancelLiveKitReconnect(resetAttempts: true);
    _speakingSyncTimer?.cancel();
    _speakingPollTimer?.cancel();
    _serverLatencyTimer?.cancel();
    _audioStatsTimer?.cancel();
    _thresholdGateReleaseTimer?.cancel();
    _windowsMicrophoneLevelIdleTimer?.cancel();
    _e2eeOldKeyRetireTimer?.cancel();
    _clearE2EEKey();
    unawaited(_screenShareTransitionTail.whenComplete(_disposeScreenRoom));
    unawaited(_disposeRoom());
    microphoneInputLevel.dispose();
    microphoneInputActive.dispose();
    super.dispose();
  }
}
