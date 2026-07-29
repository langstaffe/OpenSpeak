import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/attachment_cache_service.dart';
import 'package:openspeak_flutter/attachment_download_service.dart';
import 'package:openspeak_flutter/attachment_transfer_controller.dart';
import 'package:openspeak_flutter/device_identity_service.dart';
import 'package:openspeak_flutter/openspeak_api.dart';

void main() {
  test('encrypted bytes and ranges use the same attachment key', () async {
    final identity = DeviceIdentityService();
    final key = await identity.newChannelKey();
    final clear = Uint8List.fromList(
      List<int>.generate(1000, (index) => index % 251),
    );
    final encrypted = await identity.encryptAttachmentBytes(
      input: clear,
      channelKey: key,
      channelId: 'direct:srv:user_a:user_b',
      epochId: 'msg_test',
    );
    final api = _DownloadApi(encrypted.bytes);
    final attachment = ChatAttachment(
      direct: true,
      channelId: 'direct:srv:user_a:user_b',
      kind: 'file',
      fileId: 'file_test',
      originalName: 'secret.bin',
      contentType: 'application/octet-stream',
      sizeBytes: clear.length,
      ciphertextSizeBytes: encrypted.bytes.length,
      encryptionMode: 'e2ee',
      epochId: 'msg_test',
      nonce: encrypted.nonce,
      attachmentFormat: attachmentEncryptionFormatV1,
      expiresAt: null,
      expired: false,
    );
    final service = AttachmentDownloadService(
      AttachmentCacheService(),
      identity,
    );
    var progress = 0;

    expect(
      await service.downloadBytes(
        api: api,
        token: 'token',
        attachment: attachment,
        loadKey: () async => key,
        onProgress: (done, _) => progress = done,
      ),
      clear,
    );
    expect(progress, clear.length);

    const start = 123;
    const end = 678;
    expect(
      await service.readRange(
        api: api,
        token: 'token',
        attachment: attachment,
        start: start,
        endInclusive: end,
        loadKey: () async => key,
      ),
      clear.sublist(start, end + 1),
    );
    expect(api.rangeRequests, isNotEmpty);
  });
}

class _DownloadApi extends OpenSpeakApi {
  _DownloadApi(this.bytes) : super('http://localhost');

  final Uint8List bytes;
  final rangeRequests = <(int, int)>[];

  @override
  Future<Uint8List> downloadDirectFileBytes(
    String token,
    String fileId, {
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  @override
  Future<Uint8List> readDirectFileRange(
    String token,
    String fileId, {
    required int start,
    required int endInclusive,
    http.Client? rangeClient,
  }) async {
    rangeRequests.add((start, endInclusive));
    return bytes.sublist(start, endInclusive + 1);
  }
}
