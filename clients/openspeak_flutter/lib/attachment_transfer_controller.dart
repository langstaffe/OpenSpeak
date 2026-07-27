import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'openspeak_api.dart';

class ChatAttachment {
  ChatAttachment({
    required this.direct,
    this.channelId = '',
    required this.kind,
    required this.fileId,
    required this.originalName,
    required this.contentType,
    required this.sizeBytes,
    this.ciphertextSizeBytes = 0,
    this.encryptionMode = 'none',
    this.epochId = '',
    this.nonce = '',
    this.attachmentFormat = '',
    required this.expiresAt,
    required this.expired,
  });

  final bool direct;
  final String channelId;
  final String kind;
  final String fileId;
  final String originalName;
  final String contentType;
  final int sizeBytes;
  final int ciphertextSizeBytes;
  final String encryptionMode;
  final String epochId;
  final String nonce;
  final String attachmentFormat;
  final DateTime? expiresAt;
  final bool expired;

  String get displayName => originalName.trim().isEmpty ? fileId : originalName;

  bool get isImage => isImageContent(contentType, originalName);

  bool get isAudio => isAudioContent(contentType, originalName);

  bool get encrypted => encryptionMode == 'e2ee';
}

enum TransferStatus { queued, running, failed }

class TransferTask {
  TransferTask._({
    required this.file,
    required this.fileName,
    required this.direct,
    required this.targetId,
    required this.image,
    required this.cancelToken,
    required this.status,
    this.attachment,
  });

  factory TransferTask.upload({
    required XFile file,
    required bool direct,
    required String targetId,
    required bool image,
  }) {
    final name = file.name.isEmpty ? 'upload' : file.name;
    return TransferTask._(
      file: file,
      fileName: name,
      direct: direct,
      targetId: targetId,
      image: image,
      cancelToken: TransferCancelToken(),
      status: TransferStatus.queued,
    );
  }

  factory TransferTask.download({required ChatAttachment attachment}) {
    return TransferTask._(
      file: XFile.fromData(Uint8List(0), name: attachment.displayName),
      fileName: attachment.displayName,
      direct: attachment.direct,
      targetId: attachment.fileId,
      image: attachment.isImage,
      cancelToken: TransferCancelToken(),
      status: TransferStatus.running,
      attachment: attachment,
    );
  }

  final XFile file;
  final String fileName;
  final bool direct;
  final String targetId;
  final bool image;
  TransferCancelToken cancelToken;
  final ChatAttachment? attachment;
  TransferStatus status;
  int transferredBytes = 0;
  int totalBytes = 0;
  String? error;

  double? get progress {
    if (totalBytes <= 0) return null;
    return (transferredBytes / totalBytes).clamp(0, 1);
  }
}

class AttachmentTransferController {
  final uploads = <TransferTask>[];
  final downloads = <String, TransferTask>{};
  bool _uploadQueueRunning = false;

  TransferTask? get nextQueuedUpload {
    for (final task in uploads) {
      if (task.status == TransferStatus.queued) return task;
    }
    return null;
  }

  Future<void> processUploads({
    required Future<void> Function(TransferTask task) upload,
    required void Function() onChanged,
    void Function(TransferTask task)? onCompleted,
    void Function(TransferTask task, Object error)? onFailed,
  }) async {
    if (_uploadQueueRunning) return;
    _uploadQueueRunning = true;
    try {
      while (true) {
        final task = nextQueuedUpload;
        if (task == null) return;
        task.status = TransferStatus.running;
        onChanged();
        try {
          await upload(task);
          uploads.remove(task);
          onCompleted?.call(task);
        } catch (error) {
          if (task.cancelToken.isCancelled) {
            uploads.remove(task);
          } else {
            task.status = TransferStatus.failed;
            task.error = '$error';
            onFailed?.call(task, error);
          }
        }
        onChanged();
      }
    } finally {
      _uploadQueueRunning = false;
    }
  }

  void updateProgress(TransferTask task, int transferred, int total) {
    task.transferredBytes = transferred;
    if (total > 0) task.totalBytes = total;
  }

  void cancelUpload(TransferTask task) {
    task.cancelToken.cancel();
    if (task.status != TransferStatus.running) uploads.remove(task);
  }

  void retryUpload(TransferTask task) {
    task.cancelToken = TransferCancelToken();
    task.status = TransferStatus.queued;
    task.transferredBytes = 0;
    task.totalBytes = 0;
    task.error = null;
  }

  void cancelDownload(String fileId) {
    downloads.remove(fileId)?.cancelToken.cancel();
  }

  void cancelAndClear() {
    for (final task in uploads) {
      task.cancelToken.cancel();
    }
    for (final task in downloads.values) {
      task.cancelToken.cancel();
    }
    uploads.clear();
    downloads.clear();
  }
}

String readableBytes(int value) {
  if (value <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = value.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  final digits = unit == 0 || size >= 10 ? 0 : 1;
  return '${size.toStringAsFixed(digits)} ${units[unit]}';
}

bool isImageContent(String contentType, String name) {
  if (contentType.toLowerCase().startsWith('image/')) return true;
  final lower = name.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.bmp') ||
      lower.endsWith('.heic') ||
      lower.endsWith('.heif') ||
      lower.endsWith('.svg');
}

bool isAudioContent(String contentType, String name) {
  if (contentType.toLowerCase().startsWith('audio/')) return true;
  final lower = normalizedExtensionName(name);
  return lower.endsWith('.mp3') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.flac') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.ogg') ||
      lower.endsWith('.opus') ||
      lower.endsWith('.wma');
}

String attachmentContentType(String contentType, String name) {
  final normalized = contentType.trim();
  return normalized.isEmpty ||
          normalized.toLowerCase().split(';').first.trim() ==
              'application/octet-stream'
      ? contentTypeForPath(name)
      : normalized;
}

String normalizedExtensionName(String name) {
  var value = name.trim().toLowerCase();
  try {
    value = Uri.decodeFull(value);
  } catch (_) {
    // Keep the original value if a filename contains malformed percent escapes.
  }
  final queryIndex = value.indexOf('?');
  if (queryIndex >= 0) value = value.substring(0, queryIndex);
  final fragmentIndex = value.indexOf('#');
  if (fragmentIndex >= 0) value = value.substring(0, fragmentIndex);
  while (value.isNotEmpty &&
      ' \t\r\n.,;:!?)，。；：！？）"\''.contains(value[value.length - 1])) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}
