import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'attachment_transfer_controller.dart';
import 'openspeak_api.dart';

class AudioStreamProxy {
  HttpServer? _server;
  final _rangeClient = http.Client();
  var _nextId = 0;
  final _entries = <String, AudioStreamEntry>{};
  final _events = <String>[];

  Future<AudioProxySource> urlFor({
    required OpenSpeakApi api,
    required String token,
    required ChatAttachment attachment,
    Future<Uint8List> Function(
      http.Client rangeClient,
      int start,
      int endInclusive,
    )?
    readRange,
  }) async {
    final server = await _ensureServer();
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';
    _entries[id] = AudioStreamEntry(
      api: api,
      token: token,
      attachment: attachment,
      rangeClient: _rangeClient,
      readRange: readRange,
    );
    final uri = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: ['audio', id, safeAudioProxyName(attachment.displayName)],
    );
    return AudioProxySource(id: id, uri: uri);
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_serve(server));
    return server;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.bufferOutput = false;
    final startedAt = DateTime.now();
    var statusCode = 0;
    var bytesSent = 0;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        statusCode = response.statusCode;
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 2 ||
          segments.length > 3 ||
          segments[0] != 'audio') {
        response.statusCode = HttpStatus.notFound;
        statusCode = response.statusCode;
        return;
      }
      final entry = _entries[segments[1]];
      if (entry == null) {
        response.statusCode = HttpStatus.notFound;
        statusCode = response.statusCode;
        return;
      }
      final size = entry.attachment.sizeBytes;
      if (size <= 0) {
        response.statusCode = HttpStatus.lengthRequired;
        statusCode = response.statusCode;
        return;
      }
      final contentType = attachmentContentType(
        entry.attachment.contentType,
        entry.attachment.displayName,
      );
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final range = parseProxyRange(rangeHeader, size);
      if (rangeHeader != null && range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        statusCode = response.statusCode;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        return;
      }
      if (range == null) {
        response.statusCode = HttpStatus.ok;
        statusCode = response.statusCode;
        response.headers.contentLength = size;
        if (request.method == 'HEAD') return;
        bytesSent = await streamProxyBytes(
          response,
          entry,
          start: 0,
          end: size - 1,
        );
        return;
      }

      response.statusCode = HttpStatus.partialContent;
      statusCode = response.statusCode;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/$size',
      );
      response.headers.contentLength = range.length;
      if (request.method == 'HEAD') return;

      bytesSent = await streamProxyBytes(
        response,
        entry,
        start: range.start,
        end: range.end,
      );
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        statusCode = response.statusCode;
      } catch (_) {
        // The player may close the local stream before the proxy finishes.
      }
    } finally {
      _recordEvent(
        '${request.method} ${request.uri.path} '
        'range=${request.headers.value(HttpHeaders.rangeHeader) ?? '-'} '
        'status=${statusCode == 0 ? response.statusCode : statusCode} '
        'sent=$bytesSent '
        'in ${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );
      await response.close();
    }
  }

  String diagnostics() {
    if (_events.isEmpty) return 'audio proxy requests: none';
    return 'audio proxy requests:\n${_events.join('\n')}';
  }

  void _recordEvent(String event) {
    _events.add(event);
    if (_events.length > 8) {
      _events.removeRange(0, _events.length - 8);
    }
  }

  void cancel(String? id) {
    if (id == null) return;
    _entries[id]?.cancelled = true;
  }

  Future<void> dispose() async {
    for (final entry in _entries.values) {
      entry.cancelled = true;
    }
    _entries.clear();
    _rangeClient.close();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}

Future<int> streamProxyBytes(
  HttpResponse response,
  AudioStreamEntry entry, {
  required int start,
  required int end,
}) async {
  var offset = start;
  var sent = 0;
  while (offset <= end) {
    if (entry.cancelled) break;
    final chunkEnd = (offset + audioProxyFetchSize(start, offset) - 1).clamp(
      offset,
      end,
    );
    final bytes = entry.readRange != null
        ? await entry.readRange!(entry.rangeClient, offset, chunkEnd)
        : entry.attachment.direct
        ? await entry.api.readDirectFileRange(
            entry.token,
            entry.attachment.fileId,
            start: offset,
            endInclusive: chunkEnd,
            rangeClient: entry.rangeClient,
          )
        : await entry.api.readStoredFileRange(
            entry.token,
            entry.attachment.fileId,
            start: offset,
            endInclusive: chunkEnd,
            rangeClient: entry.rangeClient,
          );
    if (bytes.isEmpty) break;
    if (entry.cancelled) break;
    response.add(bytes);
    await response.flush();
    sent += bytes.length;
    offset += bytes.length;
  }
  return sent;
}

class AudioStreamEntry {
  AudioStreamEntry({
    required this.api,
    required this.token,
    required this.attachment,
    required this.rangeClient,
    this.readRange,
  });

  final OpenSpeakApi api;
  final String token;
  final ChatAttachment attachment;
  final http.Client rangeClient;
  final Future<Uint8List> Function(
    http.Client rangeClient,
    int start,
    int endInclusive,
  )?
  readRange;
  bool cancelled = false;
}

class AudioProxySource {
  const AudioProxySource({required this.id, required this.uri});

  final String id;
  final Uri uri;
}

class AudioProxyRange {
  const AudioProxyRange({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start + 1;
}

bool shouldReloadAudioSource({
  required bool proxySourceStopped,
  required bool localSourceAvailable,
}) => proxySourceStopped || !localSourceAvailable;

const audioProxyFetchChunkBytes = 1024 * 1024;
const audioProxyInitialBurstBytes = 768 * 1024;
const audioProxySeekBurstBytes = 128 * 1024;

int audioProxyFetchSize(int streamStart, int offset) => offset != streamStart
    ? audioProxyFetchChunkBytes
    : streamStart == 0
    ? audioProxyInitialBurstBytes
    : audioProxySeekBurstBytes;

AudioProxyRange? parseProxyRange(String? header, int size) {
  if (size <= 0) return null;
  if (header == null || header.trim().isEmpty) return null;
  var start = 0;
  var end = size - 1;
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) return null;
  final rawStart = match.group(1) ?? '';
  final rawEnd = match.group(2) ?? '';
  if (rawStart.isEmpty && rawEnd.isEmpty) return null;
  if (rawStart.isEmpty) {
    final suffix = int.tryParse(rawEnd);
    if (suffix == null || suffix <= 0) return null;
    start = (size - suffix).clamp(0, size - 1).toInt();
    end = size - 1;
  } else {
    start = int.tryParse(rawStart) ?? -1;
    if (start < 0 || start >= size) return null;
    end = rawEnd.isEmpty ? size - 1 : int.tryParse(rawEnd) ?? -1;
    if (end < start) return null;
    end = end.clamp(start, size - 1).toInt();
  }
  return AudioProxyRange(start: start, end: end);
}

String safeAudioProxyName(String name) {
  final trimmed = name.trim();
  final fallback = trimmed.isEmpty
      ? 'audio.mp3'
      : trimmed.split(RegExp(r'[/\\]')).last;
  final sanitized = fallback.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  if (sanitized.contains('.') && !sanitized.endsWith('.')) {
    return sanitized;
  }
  return '$sanitized.mp3';
}
