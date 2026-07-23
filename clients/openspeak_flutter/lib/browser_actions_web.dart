// dart:html is used only by the JavaScript Web target. Keeping it behind a
// conditional export prevents browser APIs from leaking into desktop builds.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:typed_data';

@JS('RTCPeerConnection')
external JSFunction? get _rtcPeerConnection;

bool browserSupportsWebRtc() => _rtcPeerConnection != null;

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
      ..preload = 'auto'
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
  }

  final _audio = html.AudioElement();
  final _position = StreamController<Duration>.broadcast();
  final _durationChanges = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _complete = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<html.Event>>[];
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

  void unlock() {
    if (_unlocked) return;
    _unlocked = true;
    _priming = true;
    unawaited(_audio.play().catchError((_) {}));
  }

  Future<void> playUrl(String url) {
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
}

void openBrowserUrl(String url) {
  html.window.open(url, '_blank', 'noopener,noreferrer');
}
