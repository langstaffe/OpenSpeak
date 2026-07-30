import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'attachment_transfer_controller.dart';
import 'audio_stream_proxy.dart';
import 'browser_actions.dart';
import 'openspeak_api.dart';

typedef AudioPlaybackConnection = ({OpenSpeakApi? api, AuthSession? session});
typedef LocalAudioSourceLoader =
    Future<File?> Function(ChatAttachment attachment);
typedef AudioAttachmentRangeReader =
    Future<Uint8List> Function(
      ChatAttachment attachment, {
      required int start,
      required int endInclusive,
      http.Client? rangeClient,
    });
typedef AudioAttachmentDownloader =
    Future<Uint8List> Function(ChatAttachment attachment);

Future<T> loadAfterBrowserAudioUnlock<T>({
  required void Function() unlock,
  required Future<T> Function() load,
}) {
  unlock();
  return load();
}

class AudioPlaybackController extends ChangeNotifier {
  factory AudioPlaybackController({
    required bool isWeb,
    required AudioPlaybackConnection Function() connection,
    required LocalAudioSourceLoader localSourceFile,
    required AudioAttachmentRangeReader readRange,
    required AudioAttachmentDownloader downloadBytes,
    AudioPlayer? audioPlayer,
    BrowserAudioPlayer? browserAudioPlayer,
    AudioStreamProxy? audioStreamProxy,
  }) => AudioPlaybackController._(
    isWeb,
    connection,
    localSourceFile,
    readRange,
    downloadBytes,
    audioPlayer: audioPlayer,
    browserAudioPlayer: browserAudioPlayer,
    audioStreamProxy: audioStreamProxy,
  );

  AudioPlaybackController._(
    this._isWeb,
    this._connection,
    this._localSourceFile,
    this._readRange,
    this._downloadBytes, {
    AudioPlayer? audioPlayer,
    BrowserAudioPlayer? browserAudioPlayer,
    AudioStreamProxy? audioStreamProxy,
  }) : _audioPlayer = audioPlayer ?? AudioPlayer(),
       _browserAudioPlayer = browserAudioPlayer ?? BrowserAudioPlayer(),
       _audioStreamProxy = audioStreamProxy ?? AudioStreamProxy() {
    _positionSubscription =
        (_isWeb
                ? _browserAudioPlayer.onPositionChanged
                : _audioPlayer.onPositionChanged)
            .listen((value) {
              _change(() => _position = value);
            });
    _durationSubscription =
        (_isWeb
                ? _browserAudioPlayer.onDurationChanged
                : _audioPlayer.onDurationChanged)
            .listen((value) {
              _change(() => _duration = value);
            });
    _playingSubscription =
        (_isWeb
                ? _browserAudioPlayer.onPlayingChanged
                : _audioPlayer.onPlayerStateChanged.map(
                    (state) => state == PlayerState.playing,
                  ))
            .listen((value) {
              _change(() {
                _playing = value;
                _loadingFileId = null;
              });
            });
    _completeSubscription =
        (_isWeb
                ? _browserAudioPlayer.onComplete
                : _audioPlayer.onPlayerComplete)
            .listen((_) {
              _audioStreamProxy.cancel(_activeProxyId);
              _change(() {
                _playing = false;
                _position = _duration;
                _loadingFileId = null;
                _activeProxyId = null;
              });
            });
  }

  final bool _isWeb;
  final AudioPlaybackConnection Function() _connection;
  final LocalAudioSourceLoader _localSourceFile;
  final AudioAttachmentRangeReader _readRange;
  final AudioAttachmentDownloader _downloadBytes;
  final AudioPlayer _audioPlayer;
  final BrowserAudioPlayer _browserAudioPlayer;
  final AudioStreamProxy _audioStreamProxy;

  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration> _durationSubscription;
  late final StreamSubscription<bool> _playingSubscription;
  late final StreamSubscription<void> _completeSubscription;
  ChatAttachment? _selectedAttachment;
  String? _activeFileId;
  String? _loadingFileId;
  String? _activeProxyId;
  String? _activeObjectUrl;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _disposed = false;

  ChatAttachment? get selectedAttachment => _selectedAttachment;
  String? get activeFileId => _activeFileId;
  String? get loadingFileId => _loadingFileId;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;

  Future<void> toggle(ChatAttachment attachment) async {
    if (attachment.expired) throw OpenSpeakException('文件已过期');
    if (_activeFileId == attachment.fileId &&
        _loadingFileId == attachment.fileId) {
      return;
    }
    if (_isWeb) {
      await _toggleBrowser(attachment);
    } else {
      await _toggleDesktop(attachment);
    }
  }

  Future<void> _toggleDesktop(ChatAttachment attachment) async {
    if (_activeFileId == attachment.fileId && _playing) {
      final pausedAt = _position;
      if (_activeProxyId != null) {
        _audioStreamProxy.cancel(_activeProxyId);
        await _audioPlayer.stop();
      } else {
        await _audioPlayer.pause();
      }
      _change(() {
        _playing = false;
        _position = pausedAt;
      });
      return;
    }
    if (_activeFileId == attachment.fileId && !_playing) {
      final resumeAt = _position;
      final localSourceAvailable = await _localSourceFile(attachment) != null;
      if (shouldReloadAudioSource(
        proxySourceStopped: _activeProxyId != null,
        localSourceAvailable: localSourceAvailable,
      )) {
        _change(() => _loadingFileId = attachment.fileId);
        try {
          await _prepareDesktopSource(attachment);
          if (_duration > Duration.zero && resumeAt >= _duration) {
            await _audioPlayer.seek(Duration.zero);
          } else if (resumeAt > Duration.zero) {
            await _audioPlayer.seek(resumeAt);
          }
        } catch (error) {
          if (_disposed || _activeFileId != attachment.fileId) return;
          _change(() => _loadingFileId = null);
          if (_isRecoverableProxyError(error)) return;
          rethrow;
        }
      } else if (_duration > Duration.zero && _position >= _duration) {
        await _audioPlayer.seek(Duration.zero);
      }
      await _audioPlayer.resume();
      _change(() => _playing = true);
      return;
    }

    _audioStreamProxy.cancel(_activeProxyId);
    _activeProxyId = null;
    await _audioPlayer.stop();
    if (_disposed) return;
    _change(() {
      _selectedAttachment = attachment;
      _activeFileId = attachment.fileId;
      _loadingFileId = attachment.fileId;
      _playing = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      final connection = _connection();
      if (connection.api == null || connection.session == null) {
        throw OpenSpeakException('未连接服务器');
      }
      await _prepareDesktopSource(attachment);
      if (_disposed || _activeFileId != attachment.fileId) return;
      _change(() => _loadingFileId = null);
      await _audioPlayer.resume();
    } catch (error) {
      if (_disposed || _activeFileId != attachment.fileId) return;
      _change(() {
        _loadingFileId = null;
        if (!_isRecoverableProxyError(error)) _activeFileId = null;
      });
      if (_isRecoverableProxyError(error)) return;
      rethrow;
    }
    if (_activeFileId == attachment.fileId) {
      _change(() => _loadingFileId = null);
    }
  }

  Future<void> _toggleBrowser(ChatAttachment attachment) async {
    if (_activeFileId == attachment.fileId && _playing) {
      final pausedAt = _position;
      _browserAudioPlayer.pause();
      _change(() {
        _playing = false;
        _position = pausedAt;
      });
      return;
    }
    if (_activeFileId == attachment.fileId) {
      if (_duration > Duration.zero && _position >= _duration) {
        _browserAudioPlayer.seek(Duration.zero);
      }
      await _browserAudioPlayer.resume();
      _change(() => _playing = true);
      return;
    }

    if (_activeFileId != null) _browserAudioPlayer.stop();
    _change(() {
      _selectedAttachment = attachment;
      _activeFileId = attachment.fileId;
      _loadingFileId = attachment.fileId;
      _playing = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      final connection = _connection();
      final api = connection.api;
      final session = connection.session;
      if (api == null || session == null) {
        throw OpenSpeakException('未连接服务器');
      }
      final contentType = attachmentContentType(
        attachment.contentType,
        attachment.displayName,
      );
      final streamUri = await loadAfterBrowserAudioUnlock<Uri?>(
        unlock: _browserAudioPlayer.unlock,
        load: () {
          if (attachment.encrypted ||
              contentType != attachment.contentType.trim()) {
            return Future.value();
          }
          return attachment.direct
              ? api.directFileStreamUri(session.token, attachment.fileId)
              : api.storedFileStreamUri(session.token, attachment.fileId);
        },
      );
      if (_disposed || _activeFileId != attachment.fileId) return;
      final previousObjectUrl = _activeObjectUrl;
      if (previousObjectUrl != null) revokeBrowserObjectUrl(previousObjectUrl);
      _activeObjectUrl = null;
      if (streamUri != null) {
        await _browserAudioPlayer.playUrl(streamUri.toString());
      } else if (_browserAudioPlayer.supportsStreaming) {
        await _browserAudioPlayer.playStream(
          sizeBytes: attachment.sizeBytes,
          name: attachment.displayName,
          contentType: contentType,
          readRange: (start, endInclusive) =>
              _readRange(attachment, start: start, endInclusive: endInclusive),
        );
      } else {
        final bytes = await _downloadBytes(attachment);
        if (_disposed || _activeFileId != attachment.fileId) return;
        _activeObjectUrl = createBrowserObjectUrl(bytes, contentType);
        await _browserAudioPlayer.playUrl(_activeObjectUrl!);
      }
      if (_disposed || _activeFileId != attachment.fileId) return;
      _change(() {
        _loadingFileId = null;
        _playing = true;
      });
    } catch (_) {
      if (_disposed || _activeFileId != attachment.fileId) return;
      _browserAudioPlayer.stop();
      final objectUrl = _activeObjectUrl;
      _activeObjectUrl = null;
      if (objectUrl != null) revokeBrowserObjectUrl(objectUrl);
      _change(() {
        _loadingFileId = null;
        _activeFileId = null;
      });
      rethrow;
    }
  }

  Future<void> _prepareDesktopSource(ChatAttachment attachment) async {
    _activeProxyId = null;
    final localSource = await _localSourceFile(attachment);
    if (localSource != null) {
      await _audioPlayer.setSourceDeviceFile(localSource.path);
      return;
    }
    final connection = _connection();
    final api = connection.api;
    final session = connection.session;
    if (api == null || session == null) {
      throw OpenSpeakException('未连接服务器');
    }
    final source = await _audioStreamProxy.urlFor(
      api: api,
      token: session.token,
      attachment: attachment,
      readRange: attachment.encrypted
          ? (rangeClient, start, endInclusive) => _readRange(
              attachment,
              start: start,
              endInclusive: endInclusive,
              rangeClient: rangeClient,
            )
          : null,
    );
    _activeProxyId = source.id;
    try {
      await _audioPlayer.setSourceUrl(
        source.uri.toString(),
        mimeType: attachmentContentType(
          attachment.contentType,
          attachment.displayName,
        ),
      );
    } catch (error) {
      _audioStreamProxy.cancel(source.id);
      _activeProxyId = null;
      throw OpenSpeakException(
        '$error\nsource: ${source.uri}\n${_audioStreamProxy.diagnostics()}',
      );
    }
  }

  bool _isRecoverableProxyError(Object error) {
    if (_activeProxyId == null) return false;
    final message = error.toString();
    return error is SocketException ||
        message.contains('SocketException') ||
        message.contains('Operation timed out');
  }

  Future<void> seek(Duration position) async {
    if (_isWeb) {
      _browserAudioPlayer.seek(position);
    } else {
      await _audioPlayer.seek(position);
    }
    _change(() => _position = position);
  }

  Future<void> stop() async {
    _audioStreamProxy.cancel(_activeProxyId);
    _activeProxyId = null;
    final objectUrl = _activeObjectUrl;
    _activeObjectUrl = null;
    if (objectUrl != null) revokeBrowserObjectUrl(objectUrl);
    if (_isWeb) {
      _browserAudioPlayer.stop();
    } else {
      await _audioPlayer.stop();
    }
    _change(() {
      _selectedAttachment = null;
      _activeFileId = null;
      _loadingFileId = null;
      _playing = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
  }

  void _change(void Function() update) {
    if (_disposed) return;
    update();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final objectUrl = _activeObjectUrl;
    _activeObjectUrl = null;
    if (objectUrl != null) revokeBrowserObjectUrl(objectUrl);
    unawaited(_positionSubscription.cancel());
    unawaited(_durationSubscription.cancel());
    unawaited(_playingSubscription.cancel());
    unawaited(_completeSubscription.cancel());
    unawaited(_browserAudioPlayer.dispose());
    unawaited(_audioPlayer.dispose());
    unawaited(_audioStreamProxy.dispose());
    super.dispose();
  }
}
