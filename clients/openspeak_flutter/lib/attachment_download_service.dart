import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'attachment_cache_service.dart';
import 'attachment_transfer_controller.dart';
import 'device_identity_service.dart';
import 'openspeak_api.dart';

class AttachmentDownloadService {
  AttachmentDownloadService(this.cache, this.deviceIdentity);

  final AttachmentCacheService cache;
  final DeviceIdentityService deviceIdentity;

  Future<File> ensureCached({
    required OpenSpeakApi? api,
    required String token,
    required ChatAttachment attachment,
    required File? localSource,
    required Future<SecretKey?> Function() loadKey,
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    if (attachment.expired) throw OpenSpeakException('文件已过期');
    if (localSource != null &&
        await localSource.exists() &&
        (attachment.sizeBytes <= 0 ||
            await localSource.length() == attachment.sizeBytes)) {
      return localSource;
    }
    if (!attachment.encrypted) {
      return cache.ensureCached(
        token: token,
        direct: attachment.direct,
        fileId: attachment.fileId,
        originalName: attachment.originalName,
        expectedSizeBytes: attachment.sizeBytes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }
    if (api == null) throw OpenSpeakException('无法下载加密附件');
    final existing = await cache.existingCachedFile(
      fileId: attachment.fileId,
      originalName: attachment.originalName,
      expectedSizeBytes: attachment.sizeBytes,
    );
    if (existing != null) return existing;
    _validateEncryptedFormat(attachment);
    final key = await loadKey();
    if (key == null) throw OpenSpeakException('缺少附件解密密钥');

    late final File encrypted;
    void downloadProgress(int done, int _) => onProgress?.call(
      attachment.ciphertextSizeBytes <= 0
          ? 0
          : (done * attachment.sizeBytes ~/ attachment.ciphertextSizeBytes) *
                4 ~/
                5,
      attachment.sizeBytes,
    );
    encrypted = attachment.direct
        ? await api.downloadDirectFile(
            token,
            attachment.fileId,
            '${attachment.originalName}.encrypted',
            cancelToken: cancelToken,
            onProgress: downloadProgress,
          )
        : await api.downloadStoredFile(
            token,
            attachment.fileId,
            '${attachment.originalName}.encrypted',
            cancelToken: cancelToken,
            onProgress: downloadProgress,
          );
    try {
      final cached = await cache.cachedFile(
        fileId: attachment.fileId,
        originalName: attachment.originalName,
      );
      return await deviceIdentity.decryptAttachmentFile(
        input: encrypted,
        output: cached,
        channelKey: key,
        channelId: attachment.channelId,
        epochId: attachment.epochId,
        nonce: attachment.nonce,
        plaintextSize: attachment.sizeBytes,
        checkCancelled: () => cancelToken?.throwIfCancelled('下载已取消'),
        onProgress: (done, total) =>
            onProgress?.call(total * 4 ~/ 5 + done ~/ 5, total),
      );
    } finally {
      if (await encrypted.exists()) await encrypted.delete();
    }
  }

  Future<Uint8List> downloadBytes({
    required OpenSpeakApi api,
    required String token,
    required ChatAttachment attachment,
    required Future<SecretKey?> Function() loadKey,
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    if (attachment.expired) throw OpenSpeakException('文件已过期');
    void downloadProgress(int done, int total) {
      if (!attachment.encrypted) {
        onProgress?.call(done, total);
        return;
      }
      final ciphertextSize = attachment.ciphertextSizeBytes > 0
          ? attachment.ciphertextSizeBytes
          : total;
      final plaintextSize = attachment.sizeBytes > 0
          ? attachment.sizeBytes
          : total;
      onProgress?.call(
        ciphertextSize <= 0
            ? 0
            : done * plaintextSize ~/ ciphertextSize * 4 ~/ 5,
        plaintextSize,
      );
    }

    final bytes = attachment.direct
        ? await api.downloadDirectFileBytes(
            token,
            attachment.fileId,
            onProgress: downloadProgress,
            cancelToken: cancelToken,
          )
        : await api.downloadStoredFileBytes(
            token,
            attachment.fileId,
            onProgress: downloadProgress,
            cancelToken: cancelToken,
          );
    if (!attachment.encrypted) return bytes;
    _validateEncryptedFormat(attachment);
    final key = await loadKey();
    if (key == null) throw OpenSpeakException('缺少附件解密密钥');
    return deviceIdentity.decryptAttachmentBytes(
      input: bytes,
      channelKey: key,
      channelId: attachment.channelId,
      epochId: attachment.epochId,
      nonce: attachment.nonce,
      plaintextSize: attachment.sizeBytes,
      checkCancelled: () => cancelToken?.throwIfCancelled('下载已取消'),
      onProgress: (done, total) =>
          onProgress?.call(total * 4 ~/ 5 + done ~/ 5, total),
    );
  }

  Future<Uint8List> readRange({
    required OpenSpeakApi api,
    required String token,
    required ChatAttachment attachment,
    required int start,
    required int endInclusive,
    required Future<SecretKey?> Function() loadKey,
    http.Client? rangeClient,
  }) async {
    if (!attachment.encrypted) {
      return attachment.direct
          ? api.readDirectFileRange(
              token,
              attachment.fileId,
              start: start,
              endInclusive: endInclusive,
              rangeClient: rangeClient,
            )
          : api.readStoredFileRange(
              token,
              attachment.fileId,
              start: start,
              endInclusive: endInclusive,
              rangeClient: rangeClient,
            );
    }
    _validateEncryptedFormat(attachment);
    final key = await loadKey();
    if (key == null) throw OpenSpeakException('缺少附件解密密钥');
    return deviceIdentity.decryptAttachmentRange(
      readCipherRange: (cipherStart, cipherEnd) => attachment.direct
          ? api.readDirectFileRange(
              token,
              attachment.fileId,
              start: cipherStart,
              endInclusive: cipherEnd,
              rangeClient: rangeClient,
            )
          : api.readStoredFileRange(
              token,
              attachment.fileId,
              start: cipherStart,
              endInclusive: cipherEnd,
              rangeClient: rangeClient,
            ),
      channelKey: key,
      channelId: attachment.channelId,
      epochId: attachment.epochId,
      nonce: attachment.nonce,
      plaintextSize: attachment.sizeBytes,
      start: start,
      endInclusive: endInclusive,
    );
  }

  void _validateEncryptedFormat(ChatAttachment attachment) {
    if (attachment.attachmentFormat != attachmentEncryptionFormatV1) {
      throw OpenSpeakException('不支持此加密附件格式');
    }
  }
}

bool isDirectFileExpiredError(Object error) {
  final text = '$error';
  return text.contains('HTTP 410') ||
      text.contains('file has expired') ||
      text.contains('文件已过期');
}
