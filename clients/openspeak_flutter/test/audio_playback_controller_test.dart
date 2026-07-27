import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/attachment_transfer_controller.dart';
import 'package:openspeak_flutter/audio_playback_controller.dart';
import 'package:openspeak_flutter/browser_actions.dart';
import 'package:openspeak_flutter/openspeak_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio playback controller owns the Web playback lifecycle', () async {
    final browserPlayer = _TestBrowserAudioPlayer();
    var rangeReads = 0;
    final controller = AudioPlaybackController(
      isWeb: true,
      connection: () => (
        api: OpenSpeakApi('https://example.invalid'),
        session: AuthSession(
          token: 'token',
          user: User(id: 'user', displayName: 'User'),
        ),
      ),
      localSourceFile: (_) async => null,
      readRange:
          (_, {required start, required endInclusive, rangeClient}) async {
            rangeReads += 1;
            return Uint8List(endInclusive - start + 1);
          },
      downloadBytes: (_) => fail('streaming should avoid a full download'),
      browserAudioPlayer: browserPlayer,
    );
    final attachment = ChatAttachment(
      direct: false,
      kind: 'file',
      fileId: 'song',
      originalName: 'song.flac',
      contentType: 'audio/flac',
      sizeBytes: 1024,
      encryptionMode: 'e2ee',
      expiresAt: null,
      expired: false,
    );

    await controller.toggle(attachment);
    expect(browserPlayer.unlocked, isTrue);
    expect(browserPlayer.streamStarts, 1);
    expect(rangeReads, 1);
    expect(controller.activeFileId, 'song');
    expect(controller.loadingFileId, isNull);
    expect(controller.playing, isTrue);

    browserPlayer.emitDuration(const Duration(minutes: 3));
    browserPlayer.emitPosition(const Duration(seconds: 20));
    await controller.seek(const Duration(seconds: 40));
    expect(browserPlayer.lastSeek, const Duration(seconds: 40));
    expect(controller.position, const Duration(seconds: 40));

    await controller.toggle(attachment);
    expect(browserPlayer.pauses, 1);
    expect(controller.playing, isFalse);
    await controller.toggle(attachment);
    expect(browserPlayer.resumes, 1);
    expect(controller.playing, isTrue);

    browserPlayer.emitComplete();
    expect(controller.playing, isFalse);
    expect(controller.position, const Duration(minutes: 3));
    await controller.stop();
    expect(browserPlayer.stops, 1);
    expect(controller.activeFileId, isNull);
    expect(controller.position, Duration.zero);
    controller.dispose();
  });
}

class _TestBrowserAudioPlayer extends BrowserAudioPlayer {
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration>.broadcast(sync: true);
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _completed = StreamController<void>.broadcast(sync: true);

  bool unlocked = false;
  int streamStarts = 0;
  int pauses = 0;
  int resumes = 0;
  int stops = 0;
  Duration? lastSeek;

  @override
  Stream<Duration> get onPositionChanged => _positions.stream;

  @override
  Stream<Duration> get onDurationChanged => _durations.stream;

  @override
  Stream<bool> get onPlayingChanged => _playing.stream;

  @override
  Stream<void> get onComplete => _completed.stream;

  @override
  bool get supportsStreaming => true;

  @override
  void unlock() => unlocked = true;

  @override
  Future<void> playStream({
    required int sizeBytes,
    required String name,
    required String contentType,
    required BrowserAudioRangeReader readRange,
  }) async {
    streamStarts += 1;
    await readRange(0, 1);
  }

  @override
  void pause() => pauses += 1;

  @override
  Future<void> resume() async => resumes += 1;

  @override
  void seek(Duration position) => lastSeek = position;

  @override
  void stop() => stops += 1;

  void emitPosition(Duration value) => _positions.add(value);

  void emitDuration(Duration value) => _durations.add(value);

  void emitComplete() => _completed.add(null);

  @override
  Future<void> dispose() async {
    await Future.wait([
      _positions.close(),
      _durations.close(),
      _playing.close(),
      _completed.close(),
    ]);
  }
}
