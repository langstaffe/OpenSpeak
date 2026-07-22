// LiveKit 2.8.1 waits for a peer that OpenSpeak's manual Web subscriber creates
// only after connect. Treat the signaling join as the Web connection boundary;
// later publish/subscribe operations still negotiate and validate their peers.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/engine.dart' as livekit_internal;
import 'package:livekit_client/src/internal/events.dart' as livekit_internal;
import 'package:livekit_client/src/support/region_url_provider.dart'
    as livekit_internal;

lk.Room createOpenSpeakLiveKitRoom({required lk.RoomOptions roomOptions}) {
  if (!kIsWeb) return lk.Room(roomOptions: roomOptions);
  return lk.Room(
    roomOptions: roomOptions,
    engine: WebJoinSafeEngine(
      connectOptions: const lk.ConnectOptions(),
      roomOptions: roomOptions,
    ),
  );
}

@visibleForTesting
class WebJoinSafeEngine extends livekit_internal.Engine {
  WebJoinSafeEngine({
    required super.connectOptions,
    required super.roomOptions,
    super.signalClient,
  });

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
    livekit_internal.RegionUrlProvider? regionUrlProvider,
  }) async {
    this.url = url;
    this.token = token;
    this.connectOptions = connectOptions ?? this.connectOptions;
    this.roomOptions = roomOptions ?? this.roomOptions;
    this.fastConnectOptions = fastConnectOptions;
    if (regionUrlProvider != null) setRegionUrlProvider(regionUrlProvider);

    final joinResponse = Completer<void>();
    final cancelJoinResponse = events
        .on<livekit_internal.EngineJoinResponseEvent>((_) {
          if (!joinResponse.isCompleted) joinResponse.complete();
        });
    try {
      await signalClient.connect(
        url,
        token,
        connectOptions: this.connectOptions,
        roomOptions: this.roomOptions,
      );
      await joinResponse.future.timeout(
        this.connectOptions.timeouts.connection,
        onTimeout: () => throw lk.ConnectException(
          'Timed out waiting for SignalJoinResponseEvent',
          reason: lk.ConnectionErrorReason.Timeout,
        ),
      );
      events.emit(const livekit_internal.EngineConnectedEvent());
    } catch (error) {
      lk.logger.fine('Connect Error $error');
      events.emit(
        livekit_internal.EngineDisconnectedEvent(
          reason: lk.DisconnectReason.joinFailure,
        ),
      );
      rethrow;
    } finally {
      await cancelJoinResponse();
    }
  }
}
