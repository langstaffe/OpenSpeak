import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'channel_key_controller.dart';
import 'device_identity_service.dart';
import 'direct_message.dart';
import 'openspeak_api.dart';

class AttachmentUploadService {
  AttachmentUploadService(this.deviceIdentity);

  final DeviceIdentityService deviceIdentity;

  Future<ChannelUploadResult> uploadChannel({
    required OpenSpeakApi api,
    required String token,
    required String channelId,
    required XFile file,
    required int fileLength,
    required bool image,
    required String encryptionMode,
    required E2EEDeviceIdentity? identity,
    required ChannelKeyController channelKeys,
    required TransferProgress onProgress,
    required TransferCancelToken cancelToken,
    bool isWeb = kIsWeb,
  }) async {
    Future<ChannelUploadResult> uploadOnce() async {
      if (encryptionMode != 'e2ee') {
        return _uploadChannelFile(
          api: api,
          token: token,
          channelId: channelId,
          file: file,
          image: image,
          encryptionMode: encryptionMode,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      }
      final state = await api.getChannelE2EEState(token, channelId);
      if (identity == null) {
        throw OpenSpeakException('当前设备没有端到端加密密钥');
      }
      final key = await channelKeys.ensureKey(
        api: api,
        token: token,
        identity: identity,
        channelId: channelId,
        epochId: state.epoch.id,
      );
      return _withEncryptedFile(
        file: file,
        channelKey: key,
        channelId: channelId,
        epochId: state.epoch.id,
        cancelToken: cancelToken,
        isWeb: isWeb,
        temporaryPrefix: 'openspeak_e2ee_upload_',
        use: (uploadFile, nonce) => _uploadChannelFile(
          api: api,
          token: token,
          channelId: channelId,
          file: uploadFile,
          image: image,
          encryptionMode: encryptionMode,
          originalName: _fileName(file),
          epochId: state.epoch.id,
          nonce: nonce,
          plaintextSizeBytes: fileLength,
          onProgress: onProgress,
          cancelToken: cancelToken,
        ),
      );
    }

    try {
      return await uploadOnce();
    } on OpenSpeakException catch (exception) {
      if (encryptionMode != 'e2ee' || exception.code != 'epoch_changed') {
        rethrow;
      }
      channelKeys.clearChannel(channelId);
      return uploadOnce();
    }
  }

  Future<DirectFile> uploadDirect({
    required OpenSpeakApi api,
    required String token,
    required String serverId,
    required String currentUserId,
    required String peerUserId,
    required XFile file,
    required int fileLength,
    required String encryptionMode,
    required E2EEDeviceIdentity? identity,
    required DirectMessageKeyController directMessageKeys,
    required TransferProgress onProgress,
    required TransferCancelToken cancelToken,
    bool isWeb = kIsWeb,
  }) async {
    if (encryptionMode != 'e2ee') {
      return api.uploadDirectFile(
        token,
        peerUserId,
        file,
        originalName: _fileName(file),
        contentType: contentTypeForPath(_fileName(file)),
        encryptionMode: encryptionMode,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }
    if (serverId.isEmpty || identity == null) {
      throw OpenSpeakException('私聊加密设备尚未就绪');
    }
    final prepared = await directMessageKeys.prepare(
      api: api,
      token: token,
      serverId: serverId,
      currentUserId: currentUserId,
      peerUserId: peerUserId,
      identity: identity,
    );
    final scope = directEncryptionScope(
      prepared.serverId,
      currentUserId,
      peerUserId,
    );
    return _withEncryptedFile(
      file: file,
      channelKey: prepared.key,
      channelId: scope,
      epochId: prepared.messageId,
      cancelToken: cancelToken,
      isWeb: isWeb,
      temporaryPrefix: 'openspeak_e2ee_direct_',
      use: (uploadFile, nonce) => api.uploadDirectFile(
        token,
        peerUserId,
        uploadFile,
        originalName: _fileName(file),
        contentType: contentTypeForPath(_fileName(file)),
        encryptionMode: encryptionMode,
        messageId: prepared.messageId,
        senderDeviceId: prepared.senderDeviceId,
        nonce: nonce,
        plaintextSizeBytes: fileLength,
        attachmentFormat: attachmentEncryptionFormatV1,
        chunkSize: attachmentEncryptionChunkSize,
        directEnvelopes: prepared.envelopes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<ChannelUploadResult> _uploadChannelFile({
    required OpenSpeakApi api,
    required String token,
    required String channelId,
    required XFile file,
    required bool image,
    required String encryptionMode,
    String? originalName,
    String epochId = '',
    String nonce = '',
    int plaintextSizeBytes = 0,
    required TransferProgress onProgress,
    required TransferCancelToken cancelToken,
  }) {
    final name = originalName ?? _fileName(file);
    final contentType = contentTypeForPath(name);
    final upload = image ? api.uploadChannelImage : api.uploadChannelFile;
    return upload(
      token,
      channelId,
      file,
      encryptionMode: encryptionMode,
      originalName: name,
      contentType: contentType,
      epochId: epochId,
      nonce: nonce,
      plaintextSizeBytes: plaintextSizeBytes,
      attachmentFormat: encryptionMode == 'e2ee'
          ? attachmentEncryptionFormatV1
          : '',
      chunkSize: encryptionMode == 'e2ee' ? attachmentEncryptionChunkSize : 0,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<T> _withEncryptedFile<T>({
    required XFile file,
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    required TransferCancelToken cancelToken,
    required bool isWeb,
    required String temporaryPrefix,
    required Future<T> Function(XFile file, String nonce) use,
  }) async {
    if (isWeb) {
      final encrypted = await deviceIdentity.encryptAttachmentBytes(
        input: await file.readAsBytes(),
        channelKey: channelKey,
        channelId: channelId,
        epochId: epochId,
        checkCancelled: () => cancelToken.throwIfCancelled('上传已取消'),
      );
      return use(
        XFile.fromData(encrypted.bytes, name: 'payload'),
        encrypted.nonce,
      );
    }
    final directory = await Directory.systemTemp.createTemp(temporaryPrefix);
    try {
      final encrypted = await deviceIdentity.encryptAttachmentFile(
        input: File(file.path),
        output: File('${directory.path}${Platform.pathSeparator}payload'),
        channelKey: channelKey,
        channelId: channelId,
        epochId: epochId,
        checkCancelled: () => cancelToken.throwIfCancelled('上传已取消'),
      );
      return await use(XFile(encrypted.file.path), encrypted.nonce);
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

String _fileName(XFile file) => file.name.isEmpty ? 'upload' : file.name;
