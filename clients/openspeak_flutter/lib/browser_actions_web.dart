// dart:html is used only by the JavaScript Web target. Keeping it behind a
// conditional export prevents browser APIs from leaking into desktop builds.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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
  final request = html.HttpRequest();
  final result = Completer<BrowserUploadResponse>();
  var transferred = 0;
  var total = bytes.length;

  void fail(BrowserUploadException error) {
    if (!result.isCompleted) result.completeError(error);
  }

  request.upload.onProgress.listen((event) {
    if (result.isCompleted) return;
    transferred = event.loaded ?? transferred;
    if (event.lengthComputable && (event.total ?? 0) > 0) {
      total = event.total!;
    }
    onProgress?.call(transferred, total);
  });
  request
    ..open(method, uri.toString())
    ..responseType = 'text';
  for (final header in headers.entries) {
    request.setRequestHeader(header.key, header.value);
  }
  request.onLoad.listen((_) {
    if (result.isCompleted) return;
    onProgress?.call(total, total);
    result.complete(
      BrowserUploadResponse(
        statusCode: request.status ?? 0,
        body: request.responseText ?? '',
      ),
    );
  });
  request.onError.listen(
    (_) => fail(const BrowserUploadException('浏览器上传网络请求失败')),
  );
  request.onAbort.listen(
    (_) => fail(const BrowserUploadException('上传已取消', aborted: true)),
  );
  cancelled?.then((_) {
    if (!result.isCompleted) request.abort();
  });

  onProgress?.call(0, total);
  if (fieldName == null) {
    request.setRequestHeader('Content-Type', contentType);
    request.send(html.Blob([bytes], contentType));
  } else {
    final form = html.FormData();
    for (final field in fields.entries) {
      form.append(field.key, field.value);
    }
    form.appendBlob(
      fieldName,
      html.Blob([bytes], contentType),
      fileName ?? 'upload',
    );
    request.send(form);
  }
  return result.future;
}

@JS('RTCPeerConnection')
external JSFunction? get _rtcPeerConnection;

@JS('navigator.mediaDevices')
external JSObject? get _mediaDevices;

@JS('openSpeakAudioStreamWorkerReady')
external bool? get _audioStreamWorkerReady;

bool browserSupportsWebRtc() => _rtcPeerConnection != null;

bool browserSupportsScreenShare() =>
    _mediaDevices?['getDisplayMedia']?.isA<JSFunction>() == true;

typedef BrowserAudioRangeReader =
    Future<Uint8List> Function(int start, int endInclusive);

String? readBrowserSessionValue(String key) {
  try {
    return html.window.sessionStorage[key];
  } catch (_) {
    return null;
  }
}

void writeBrowserSessionValue(String key, String value) {
  try {
    html.window.sessionStorage[key] = value;
  } catch (_) {
    // Private browsing policies may disable storage; login still works.
  }
}

void removeBrowserSessionValue(String key) {
  try {
    html.window.sessionStorage.remove(key);
  } catch (_) {
    // Nothing to clear when storage is unavailable.
  }
}

void downloadBrowserBytes(Uint8List bytes, String name, String contentType) {
  final url = createBrowserObjectUrl(bytes, contentType);
  final anchor = html.AnchorElement(href: url)
    ..download = name
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 1),
    () => revokeBrowserObjectUrl(url),
  );
}

String createBrowserObjectUrl(Uint8List bytes, String contentType) =>
    html.Url.createObjectUrlFromBlob(html.Blob([bytes], contentType));

void revokeBrowserObjectUrl(String url) => html.Url.revokeObjectUrl(url);

class BrowserAudioPlayer {
  BrowserAudioPlayer() {
    _audio
      ..preload = 'metadata'
      ..crossOrigin = 'anonymous'
      ..src = _unlockSource
      ..style.display = 'none';
    html.document.body?.append(_audio);
    _subscriptions.addAll([
      _audio.onTimeUpdate.listen((_) {
        if (!_priming) _position.add(_duration(_audio.currentTime));
      }),
      _audio.onDurationChange.listen((_) {
        if (!_priming) _durationChanges.add(_duration(_audio.duration));
      }),
      _audio.onPlay.listen((_) {
        if (!_priming) _playing.add(true);
      }),
      _audio.onPause.listen((_) {
        if (!_priming) _playing.add(false);
      }),
      _audio.onEnded.listen((_) {
        if (_priming) return;
        _playing.add(false);
        _complete.add(null);
      }),
    ]);
    _workerSubscription = html.window.navigator.serviceWorker?.onMessage.listen(
      _handleWorkerMessage,
    );
  }

  final _audio = html.AudioElement();
  final _position = StreamController<Duration>.broadcast();
  final _durationChanges = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _complete = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<html.Event>>[];
  final _streamReaders = <String, BrowserAudioRangeReader>{};
  StreamSubscription<html.MessageEvent>? _workerSubscription;
  String? _activeStreamId;
  var _nextStreamId = 0;
  var _priming = true;
  var _unlocked = false;

  static const _unlockSource =
      'data:audio/wav;base64,'
      'UklGRsQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YaAAAACAgICA'
      'gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA'
      'gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA'
      'gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA'
      'gICAgICAgICAgICA';

  Stream<Duration> get onPositionChanged => _position.stream;

  Stream<Duration> get onDurationChanged => _durationChanges.stream;

  Stream<bool> get onPlayingChanged => _playing.stream;

  Stream<void> get onComplete => _complete.stream;

  bool get supportsStreaming =>
      _audioStreamWorkerReady == true &&
      html.window.navigator.serviceWorker?.controller != null;

  void unlock() {
    if (_unlocked) return;
    _unlocked = true;
    _priming = true;
    unawaited(_audio.play().catchError((_) {}));
  }

  Future<void> playUrl(String url) {
    _clearStreamSource();
    return _playUrl(url);
  }

  Future<void> playStream({
    required int sizeBytes,
    required String name,
    required String contentType,
    required BrowserAudioRangeReader readRange,
  }) async {
    if (!supportsStreaming) {
      throw UnsupportedError('Browser audio streaming is unavailable');
    }
    _clearStreamSource();
    final sourceId =
        '${DateTime.now().microsecondsSinceEpoch}-${_nextStreamId++}';
    _activeStreamId = sourceId;
    _streamReaders[sourceId] = readRange;
    final baseUri = Uri.parse(
      html.document.baseUri ?? html.window.location.href,
    );
    final uri = baseUri
        .resolve('__openspeak_audio__/$sourceId/${Uri.encodeComponent(name)}')
        .replace(queryParameters: {'size': '$sizeBytes', 'type': contentType});
    try {
      await _playUrl(uri.toString());
    } catch (_) {
      _clearStreamSource();
      rethrow;
    }
  }

  Future<void> _playUrl(String url) {
    _unlocked = true;
    _priming = false;
    _audio
      ..src = url
      ..load();
    return _audio.play();
  }

  Future<void> resume() {
    _priming = false;
    return _audio.play();
  }

  void pause() => _audio.pause();

  void seek(Duration position) {
    _audio.currentTime = position.inMilliseconds / 1000;
  }

  void stop() {
    _clearStreamSource();
    _priming = true;
    _audio.pause();
    _audio.currentTime = 0;
  }

  Future<void> dispose() async {
    _audio
      ..pause()
      ..remove();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _workerSubscription?.cancel();
    await Future.wait([
      _position.close(),
      _durationChanges.close(),
      _playing.close(),
      _complete.close(),
    ]);
  }

  static Duration _duration(num? seconds) {
    final value = seconds?.toDouble() ?? 0;
    if (!value.isFinite || value <= 0) return Duration.zero;
    return Duration(milliseconds: (value * 1000).round());
  }

  void _clearStreamSource() {
    final sourceId = _activeStreamId;
    _activeStreamId = null;
    if (sourceId != null) _streamReaders.remove(sourceId);
  }

  void _handleWorkerMessage(html.MessageEvent event) {
    final data = event.data;
    if (data is! Map || data['type'] != 'openspeak-audio-range-request') {
      return;
    }
    final requestId = data['requestId']?.toString();
    final sourceId = data['sourceId']?.toString();
    final start = (data['start'] as num?)?.toInt();
    final endInclusive = (data['endInclusive'] as num?)?.toInt();
    if (requestId == null ||
        sourceId == null ||
        start == null ||
        endInclusive == null) {
      return;
    }
    final reader = _streamReaders[sourceId];
    if (reader == null) {
      _postRangeResult(requestId, error: 'audio stream is no longer active');
      return;
    }
    unawaited(() async {
      try {
        final bytes = await reader(start, endInclusive);
        _postRangeResult(requestId, bytes: bytes);
      } catch (error) {
        _postRangeResult(requestId, error: '$error');
      }
    }());
  }

  void _postRangeResult(String requestId, {Uint8List? bytes, String? error}) {
    html.window.navigator.serviceWorker?.controller?.postMessage({
      'type': 'openspeak-audio-range-result',
      'requestId': requestId,
      'bytes': ?bytes,
      'error': ?error,
    });
  }
}

void openBrowserUrl(String url) {
  html.window.open(url, '_blank', 'noopener,noreferrer');
}
