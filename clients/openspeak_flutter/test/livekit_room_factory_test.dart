// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/signal_client.dart' as livekit_internal;
import 'package:livekit_client/src/internal/events.dart' as livekit_internal;
import 'package:livekit_client/src/proto/livekit_models.pb.dart'
    as livekit_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as livekit_rtc;
import 'package:openspeak_flutter/livekit_room_factory.dart';
import 'package:openspeak_flutter/voice_session_controller.dart';

class _ImmediateJoinSignalClient extends livekit_internal.SignalClient {
  _ImmediateJoinSignalClient()
    : super((_, {options, headers}) async => throw UnimplementedError());

  late void Function() onConnect;

  @override
  Future<void> connect(
    String uriString,
    String token, {
    required lk.ConnectOptions connectOptions,
    required lk.RoomOptions roomOptions,
    bool reconnect = false,
    livekit_models.ReconnectReason? reconnectReason,
  }) async {
    onConnect();
  }
}

void main() {
  test('room factory patches only Web', () async {
    final room = createOpenSpeakLiveKitRoom(
      roomOptions: const lk.RoomOptions(),
    );
    expect(room.engine is WebJoinSafeEngine, kIsWeb);
    await room.dispose();
  });

  test('Web microphone always keeps audio processing constraints', () {
    final enabled = voiceAudioCaptureOptions(
      noiseSuppressionEnabled: true,
      deviceId: 'microphone-1',
    ).toMediaConstraintsMap();
    final disabled = voiceAudioCaptureOptions(
      noiseSuppressionEnabled: false,
      deviceId: 'microphone-1',
    ).toMediaConstraintsMap();
    final systemDefault = voiceAudioCaptureOptions(
      noiseSuppressionEnabled: false,
    ).toMediaConstraintsMap();

    if (kIsWeb) {
      expect(enabled['deviceId'], isNotNull);
      expect(enabled['optional'], isNull);
      expect(enabled['echoCancellation'], isTrue);
      expect(enabled['autoGainControl'], isTrue);
      expect(enabled['noiseSuppression'], isTrue);
      expect(enabled['voiceIsolation'], isTrue);
      expect(disabled['echoCancellation'], isTrue);
      expect(disabled['autoGainControl'], isTrue);
      expect(disabled['noiseSuppression'], isTrue);
      expect(disabled['voiceIsolation'], isTrue);
      expect(systemDefault['optional'], isNull);
      expect(systemDefault['echoCancellation'], isTrue);
      expect(systemDefault['autoGainControl'], isTrue);
      expect(systemDefault['noiseSuppression'], isTrue);
      expect(systemDefault['voiceIsolation'], isTrue);
    } else {
      expect(enabled['optional'], isNotEmpty);
      expect(disabled['noiseSuppression'], isNull);
    }
  });

  test('web engine connects after an immediate signaling join', () async {
    final signalClient = _ImmediateJoinSignalClient();
    final engine = WebJoinSafeEngine(
      connectOptions: const lk.ConnectOptions(),
      roomOptions: const lk.RoomOptions(),
      signalClient: signalClient,
    );
    signalClient.onConnect = () {
      engine.events.emit(
        livekit_internal.EngineJoinResponseEvent(
          response: livekit_rtc.JoinResponse(),
        ),
      );
    };

    await engine.connect('wss://voice.example', 'token');
    await engine.dispose();
  });
}
