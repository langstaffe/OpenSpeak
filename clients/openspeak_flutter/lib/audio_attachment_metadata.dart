import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const audioMetadataReadLimitBytes = 8 * 1024 * 1024;

class AudioAttachmentMetadata {
  const AudioAttachmentMetadata({
    this.title = '',
    this.artist = '',
    this.coverBytes,
  });

  final String title;
  final String artist;
  final Uint8List? coverBytes;

  bool get hasContent =>
      title.trim().isNotEmpty || artist.trim().isNotEmpty || coverBytes != null;

  AudioAttachmentMetadata withFallbackTitle(String fallback) {
    return AudioAttachmentMetadata(
      title: title.trim().isEmpty ? fallback : title,
      artist: artist,
      coverBytes: coverBytes,
    );
  }
}

Future<AudioAttachmentMetadata> readAudioAttachmentMetadataFromFile(
  File file,
) async {
  try {
    final fileLength = await file.length();
    Future<Uint8List> readRange(int start, int endInclusive) async {
      if (fileLength <= 0 || start > endInclusive) return Uint8List(0);
      final clampedStart = start.clamp(0, fileLength - 1).toInt();
      final clampedEnd = endInclusive.clamp(0, fileLength - 1).toInt();
      if (clampedStart > clampedEnd) return Uint8List(0);
      final random = await file.open();
      try {
        await random.setPosition(clampedStart);
        return await random.read(clampedEnd - clampedStart + 1);
      } finally {
        await random.close();
      }
    }

    final header = await readRange(0, 9);
    if (header.length != 10 ||
        header[0] != 0x49 ||
        header[1] != 0x44 ||
        header[2] != 0x33) {
      if (header.length >= 4 &&
          header[0] == 0x66 &&
          header[1] == 0x4C &&
          header[2] == 0x61 &&
          header[3] == 0x43) {
        final initial = await readRange(0, 64 * 1024 - 1);
        final metadataLength = flacMetadataLength(initial);
        if (metadataLength > initial.length &&
            metadataLength <= audioMetadataReadLimitBytes) {
          return parseFlacMetadata(await readRange(0, metadataLength - 1));
        }
        return parseFlacMetadata(initial);
      }
      return readMp4MetadataFromRanges(
        sizeBytes: fileLength,
        readRange: readRange,
      );
    }
    final tagSize = readSynchsafeInt(header, 6);
    if (tagSize <= 0 || tagSize > audioMetadataReadLimitBytes) {
      return const AudioAttachmentMetadata();
    }
    final tag = await readRange(10, tagSize + 9);
    return parseID3v2Metadata(
      tag,
      majorVersion: header[3],
      unsynchronized: (header[5] & 0x80) != 0,
      extendedHeader: (header[5] & 0x40) != 0,
    );
  } catch (_) {
    return const AudioAttachmentMetadata();
  }
}

AudioAttachmentMetadata parseID3v2Metadata(
  Uint8List tag, {
  int majorVersion = 3,
  bool unsynchronized = false,
  bool extendedHeader = false,
}) {
  var offset = 0;
  var title = '';
  var artist = '';
  Uint8List? cover;
  if (extendedHeader && majorVersion == 3 && tag.length >= 4) {
    final extendedHeaderSize = _readUint32BE(tag, 0);
    if (extendedHeaderSize > 0 && extendedHeaderSize + 4 <= tag.length) {
      offset = extendedHeaderSize + 4;
    }
  } else if (extendedHeader && majorVersion == 4 && tag.length >= 4) {
    final extendedHeaderSize = readSynchsafeInt(tag, 0);
    if (extendedHeaderSize > 0 && extendedHeaderSize <= tag.length) {
      offset = extendedHeaderSize;
    }
  }
  while (offset + 10 <= tag.length) {
    final frameId = String.fromCharCodes(tag.sublist(offset, offset + 4));
    if (frameId.trim().isEmpty ||
        frameId.codeUnits.any((unit) => unit < 0x20 || unit > 0x7E)) {
      break;
    }
    final frameSize = _readID3FrameSize(tag, offset + 4, majorVersion);
    final frameFlags = tag.sublist(offset + 8, offset + 10);
    offset += 10;
    if (frameSize <= 0 || offset + frameSize > tag.length) break;
    var frame = Uint8List.sublistView(tag, offset, offset + frameSize);
    if (majorVersion == 4 && (frameFlags[1] & 0x01) != 0) {
      if (frame.length <= 4) {
        offset += frameSize;
        continue;
      }
      frame = Uint8List.sublistView(frame, 4);
    }
    if (unsynchronized || (majorVersion == 4 && (frameFlags[1] & 0x02) != 0)) {
      frame = _removeID3Unsynchronization(frame);
    }
    if (frameId == 'TIT2') {
      title = _decodeID3TextFrame(frame);
    } else if (frameId == 'TPE1') {
      artist = _decodeID3TextFrame(frame);
    } else if (frameId == 'APIC') {
      cover ??= _extractID3Cover(frame);
    }
    offset += frameSize;
  }
  return AudioAttachmentMetadata(
    title: title,
    artist: artist,
    coverBytes: cover,
  );
}

int flacMetadataLength(Uint8List bytes) {
  if (bytes.length < 4 ||
      bytes[0] != 0x66 ||
      bytes[1] != 0x4C ||
      bytes[2] != 0x61 ||
      bytes[3] != 0x43) {
    return 0;
  }
  var offset = 4;
  while (offset + 4 <= bytes.length) {
    final isLastBlock = (bytes[offset] & 0x80) != 0;
    final blockLength = _readUint24BE(bytes, offset + 1);
    offset += 4;
    final nextOffset = offset + blockLength;
    if (nextOffset > bytes.length) return nextOffset;
    offset = nextOffset;
    if (isLastBlock) return offset;
  }
  return bytes.length;
}

AudioAttachmentMetadata parseFlacMetadata(Uint8List bytes) {
  if (bytes.length < 4 ||
      bytes[0] != 0x66 ||
      bytes[1] != 0x4C ||
      bytes[2] != 0x61 ||
      bytes[3] != 0x43) {
    return const AudioAttachmentMetadata();
  }
  var offset = 4;
  var title = '';
  var artist = '';
  Uint8List? cover;
  Uint8List? fallbackCover;

  while (offset + 4 <= bytes.length) {
    final blockHeader = bytes[offset];
    final isLastBlock = (blockHeader & 0x80) != 0;
    final blockType = blockHeader & 0x7F;
    final blockLength = _readUint24BE(bytes, offset + 1);
    offset += 4;
    if (blockLength < 0 || offset + blockLength > bytes.length) break;
    final block = Uint8List.sublistView(bytes, offset, offset + blockLength);

    if (blockType == 4) {
      final comments = _parseFlacVorbisComments(block);
      title = title.isEmpty ? comments.$1 : title;
      artist = artist.isEmpty ? comments.$2 : artist;
    } else if (blockType == 6) {
      final picture = _extractFlacPicture(block);
      if (picture != null) {
        if (picture.$1 == 3) {
          cover ??= picture.$2;
        } else {
          fallbackCover ??= picture.$2;
        }
      }
    }

    offset += blockLength;
    if (isLastBlock) break;
  }

  return AudioAttachmentMetadata(
    title: title,
    artist: artist,
    coverBytes: cover ?? fallbackCover,
  );
}

(String, String) _parseFlacVorbisComments(Uint8List block) {
  var offset = 0;
  if (offset + 4 > block.length) return ('', '');
  final vendorLength = _readUint32LE(block, offset);
  offset += 4 + vendorLength;
  if (vendorLength < 0 || offset + 4 > block.length) return ('', '');
  final commentCount = _readUint32LE(block, offset);
  offset += 4;

  var title = '';
  var artist = '';
  for (var i = 0; i < commentCount && offset + 4 <= block.length; i += 1) {
    final commentLength = _readUint32LE(block, offset);
    offset += 4;
    if (commentLength < 0 || offset + commentLength > block.length) break;
    final comment = utf8.decode(
      Uint8List.sublistView(block, offset, offset + commentLength),
      allowMalformed: true,
    );
    offset += commentLength;
    final equalsIndex = comment.indexOf('=');
    if (equalsIndex <= 0) continue;
    final key = comment.substring(0, equalsIndex).toUpperCase();
    final value = comment.substring(equalsIndex + 1).trim();
    if (key == 'TITLE' && title.isEmpty) {
      title = value;
    } else if ((key == 'ARTIST' || key == 'ALBUMARTIST') && artist.isEmpty) {
      artist = value;
    }
  }
  return (title, artist);
}

(int, Uint8List)? _extractFlacPicture(Uint8List block) {
  var offset = 0;
  if (offset + 8 > block.length) return null;
  final pictureType = _readUint32BE(block, offset);
  offset += 4;
  final mimeLength = _readUint32BE(block, offset);
  offset += 4 + mimeLength;
  if (mimeLength < 0 || offset + 4 > block.length) return null;
  final descriptionLength = _readUint32BE(block, offset);
  offset += 4 + descriptionLength;
  if (descriptionLength < 0 || offset + 20 > block.length) return null;
  offset += 16;
  final dataLength = _readUint32BE(block, offset);
  offset += 4;
  if (dataLength <= 0 || offset + dataLength > block.length) return null;
  return (
    pictureType,
    Uint8List.fromList(block.sublist(offset, offset + dataLength)),
  );
}

int readSynchsafeInt(Uint8List bytes, int offset) {
  return (bytes[offset] << 21) |
      (bytes[offset + 1] << 14) |
      (bytes[offset + 2] << 7) |
      bytes[offset + 3];
}

class _Mp4Atom {
  const _Mp4Atom({
    required this.offset,
    required this.size,
    required this.headerSize,
    required this.type,
  });

  final int offset;
  final int size;
  final int headerSize;
  final String type;

  int get payloadStart => offset + headerSize;
  int get end => offset + size;
  int get endInclusive => end - 1;
}

Future<AudioAttachmentMetadata> readMp4MetadataFromRanges({
  required int sizeBytes,
  required Future<Uint8List> Function(int start, int endInclusive) readRange,
}) async {
  if (sizeBytes < 8) return const AudioAttachmentMetadata();
  final moov = await _findTopLevelMp4Atom(
    sizeBytes: sizeBytes,
    targetType: 'moov',
    readRange: readRange,
  );
  if (moov == null ||
      moov.size <= 0 ||
      moov.size > audioMetadataReadLimitBytes) {
    return const AudioAttachmentMetadata();
  }
  final bytes = await readRange(moov.offset, moov.endInclusive);
  if (bytes.length < moov.size) return const AudioAttachmentMetadata();
  return parseMp4Metadata(bytes);
}

Future<_Mp4Atom?> _findTopLevelMp4Atom({
  required int sizeBytes,
  required String targetType,
  required Future<Uint8List> Function(int start, int endInclusive) readRange,
}) async {
  var offset = 0;
  for (var i = 0; i < 256 && offset + 8 <= sizeBytes; i += 1) {
    final header = await readRange(
      offset,
      math.min(offset + 15, sizeBytes - 1),
    );
    final atom = _readMp4AtomHeader(header, 0, sizeBytes - offset);
    if (atom == null || atom.size <= 0) return null;
    final absolute = _Mp4Atom(
      offset: offset,
      size: atom.size,
      headerSize: atom.headerSize,
      type: atom.type,
    );
    if (absolute.type == targetType) return absolute;
    offset += absolute.size;
  }
  return null;
}

AudioAttachmentMetadata parseMp4Metadata(Uint8List bytes) {
  var title = '';
  var artist = '';
  Uint8List? cover;

  void walk(int start, int end, {String? parent}) {
    var offset = start;
    while (offset + 8 <= end) {
      final atom = _readMp4AtomHeader(bytes, offset, end - offset);
      if (atom == null || atom.end > end) break;
      var payloadStart = atom.payloadStart;
      final payloadEnd = atom.end;
      if (atom.type == 'data' && parent != null) {
        if (payloadStart + 8 <= payloadEnd) {
          final payload = Uint8List.sublistView(
            bytes,
            payloadStart + 8,
            payloadEnd,
          );
          if (parent == '©nam' && title.isEmpty) {
            title = _decodeMp4Text(payload);
          } else if ((parent == '©ART' || parent == 'aART') && artist.isEmpty) {
            artist = _decodeMp4Text(payload);
          } else if (parent == 'covr') {
            cover ??= _looksLikeImage(payload)
                ? Uint8List.fromList(payload)
                : _findID3EmbeddedImage(payload);
          }
        }
      } else {
        if (atom.type == 'meta') {
          payloadStart += 4;
        }
        if (payloadStart < payloadEnd && _isMp4ContainerAtom(atom.type)) {
          walk(payloadStart, payloadEnd, parent: atom.type);
        } else if (payloadStart < payloadEnd && parent == 'ilst') {
          walk(payloadStart, payloadEnd, parent: atom.type);
        }
      }
      offset = atom.end;
    }
  }

  walk(0, bytes.length);
  return AudioAttachmentMetadata(
    title: title,
    artist: artist,
    coverBytes: cover,
  );
}

bool _isMp4ContainerAtom(String type) {
  return type == 'moov' || type == 'udta' || type == 'meta' || type == 'ilst';
}

String _decodeMp4Text(Uint8List bytes) {
  return utf8
      .decode(bytes, allowMalformed: true)
      .replaceAll('\u0000', '')
      .trim();
}

_Mp4Atom? _readMp4AtomHeader(Uint8List bytes, int offset, int remainingSize) {
  if (offset + 8 > bytes.length || remainingSize < 8) return null;
  final size32 = _readUint32BE(bytes, offset);
  final type = latin1.decode(
    Uint8List.sublistView(bytes, offset + 4, offset + 8),
  );
  var size = size32;
  var headerSize = 8;
  if (size32 == 1) {
    if (offset + 16 > bytes.length || remainingSize < 16) return null;
    size = _readUint64BE(bytes, offset + 8);
    headerSize = 16;
  } else if (size32 == 0) {
    size = remainingSize;
  }
  if (size < headerSize || size > remainingSize) return null;
  return _Mp4Atom(
    offset: offset,
    size: size,
    headerSize: headerSize,
    type: type,
  );
}

int _readID3FrameSize(Uint8List bytes, int offset, int majorVersion) {
  if (majorVersion == 4) {
    return readSynchsafeInt(bytes, offset);
  }
  return _readUint32BE(bytes, offset);
}

Uint8List _removeID3Unsynchronization(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < bytes.length; i += 1) {
    out.addByte(bytes[i]);
    if (bytes[i] == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
      i += 1;
    }
  }
  return out.toBytes();
}

int _readUint24BE(Uint8List bytes, int offset) {
  return (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
}

int _readUint32BE(Uint8List bytes, int offset) {
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

int _readUint64BE(Uint8List bytes, int offset) {
  return (_readUint32BE(bytes, offset) << 32) |
      _readUint32BE(bytes, offset + 4);
}

int _readUint32LE(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

String _decodeID3TextFrame(Uint8List frame) {
  if (frame.isEmpty) return '';
  final encoding = frame[0];
  final payload = frame.sublist(1);
  try {
    if (encoding == 1 || encoding == 2) {
      return _decodeUtf16(payload).trim();
    }
    return utf8
        .decode(payload, allowMalformed: true)
        .replaceAll('\u0000', '')
        .trim();
  } catch (_) {
    return '';
  }
}

String _decodeUtf16(Uint8List bytes) {
  if (bytes.length < 2) return '';
  var offset = 0;
  var littleEndian = false;
  if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
    littleEndian = true;
    offset = 2;
  } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
    offset = 2;
  }
  final codeUnits = <int>[];
  for (var i = offset; i + 1 < bytes.length; i += 2) {
    final unit = littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1];
    if (unit == 0) continue;
    codeUnits.add(unit);
  }
  return String.fromCharCodes(codeUnits);
}

Uint8List? _extractID3Cover(Uint8List frame) {
  if (frame.length < 4) return null;
  var offset = 1;
  while (offset < frame.length && frame[offset] != 0) {
    offset += 1;
  }
  offset += 1;
  if (offset >= frame.length) return null;
  offset += 1;
  if (offset >= frame.length) return null;
  final encoding = frame[0];
  if (encoding == 1 || encoding == 2) {
    while (offset + 1 < frame.length &&
        !(frame[offset] == 0 && frame[offset + 1] == 0)) {
      offset += 2;
    }
    offset += 2;
  } else {
    while (offset < frame.length && frame[offset] != 0) {
      offset += 1;
    }
    offset += 1;
  }
  if (offset >= frame.length) return _findID3EmbeddedImage(frame);
  final image = Uint8List.fromList(frame.sublist(offset));
  return _looksLikeImage(image) ? image : _findID3EmbeddedImage(frame);
}

Uint8List? _findID3EmbeddedImage(Uint8List frame) {
  final signatures = <List<int>>[
    [0xFF, 0xD8, 0xFF],
    [0x89, 0x50, 0x4E, 0x47],
    [0x47, 0x49, 0x46, 0x38],
    [0x52, 0x49, 0x46, 0x46],
  ];
  for (final signature in signatures) {
    final offset = _indexOfBytes(frame, signature);
    if (offset >= 0) {
      return Uint8List.fromList(frame.sublist(offset));
    }
  }
  return null;
}

bool _looksLikeImage(Uint8List bytes) {
  return _startsWithBytes(bytes, [0xFF, 0xD8, 0xFF]) ||
      _startsWithBytes(bytes, [0x89, 0x50, 0x4E, 0x47]) ||
      _startsWithBytes(bytes, [0x47, 0x49, 0x46, 0x38]) ||
      (_startsWithBytes(bytes, [0x52, 0x49, 0x46, 0x46]) &&
          bytes.length >= 12 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50);
}

bool _startsWithBytes(Uint8List bytes, List<int> pattern) {
  if (bytes.length < pattern.length) return false;
  for (var i = 0; i < pattern.length; i += 1) {
    if (bytes[i] != pattern[i]) return false;
  }
  return true;
}

int _indexOfBytes(Uint8List bytes, List<int> pattern) {
  if (pattern.isEmpty || pattern.length > bytes.length) return -1;
  for (var i = 0; i <= bytes.length - pattern.length; i += 1) {
    var matched = true;
    for (var j = 0; j < pattern.length; j += 1) {
      if (bytes[i + j] != pattern[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
}
