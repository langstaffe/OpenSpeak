import 'dart:async';
import 'dart:typed_data';

class BrowserUploadResponse {
  const BrowserUploadResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class BrowserUploadException implements Exception {
  const BrowserUploadException(this.message, {this.aborted = false});

  final String message;
  final bool aborted;

  @override
  String toString() => message;
}

Future<BrowserUploadResponse> sendBrowserUpload({
  required String method,
  required Uri uri,
  required Uint8List bytes,
  required String contentType,
  Map<String, String> headers = const {},
  Map<String, String> fields = const {},
  String? fieldName,
  String? fileName,
  void Function(int transferred, int total)? onProgress,
  Future<void>? cancelled,
}) {
  throw UnsupportedError('Browser uploads are unavailable');
}

bool browserSupportsWebRtc() => true;

bool browserSupportsScreenShare() => true;

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
