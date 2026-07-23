import 'dart:async';
import 'dart:typed_data';

bool browserSupportsWebRtc() => true;

typedef BrowserAudioRangeReader =
    Future<Uint8List> Function(int start, int endInclusive);

String? readBrowserSessionValue(String key) => null;

void writeBrowserSessionValue(String key, String value) {}

void removeBrowserSessionValue(String key) {}

void downloadBrowserBytes(Uint8List bytes, String name, String contentType) {
  throw UnsupportedError('Browser downloads are unavailable');
}

String createBrowserObjectUrl(Uint8List bytes, String contentType) {
  throw UnsupportedError('Browser object URLs are unavailable');
}

void revokeBrowserObjectUrl(String url) {}

class BrowserAudioPlayer {
  Stream<Duration> get onPositionChanged => const Stream.empty();

  Stream<Duration> get onDurationChanged => const Stream.empty();

  Stream<bool> get onPlayingChanged => const Stream.empty();

  Stream<void> get onComplete => const Stream.empty();

  bool get supportsStreaming => false;

  void unlock() {}

  Future<void> playUrl(String url) {
    throw UnsupportedError('Browser audio is unavailable');
  }

  Future<void> playStream({
    required int sizeBytes,
    required String name,
    required String contentType,
    required BrowserAudioRangeReader readRange,
  }) {
    throw UnsupportedError('Browser audio streaming is unavailable');
  }

  Future<void> resume() {
    throw UnsupportedError('Browser audio is unavailable');
  }

  void pause() {}

  void seek(Duration position) {}

  void stop() {}

  Future<void> dispose() async {}
}

void openBrowserUrl(String url) {
  throw UnsupportedError('Browser navigation is unavailable');
}
