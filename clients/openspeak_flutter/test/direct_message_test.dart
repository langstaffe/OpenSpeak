import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/direct_message.dart';
import 'package:openspeak_flutter/openspeak_api.dart';

void main() {
  test('direct messages parse encrypted file metadata and replace body', () {
    final sentAt = DateTime.utc(2026, 7, 17);
    final message = DirectMessage.fromEvent(
      RealtimeEvent(
        type: 'direct.message_created',
        serverId: 'server',
        channelId: '',
        fromUser: 'sender',
        toUser: 'recipient',
        payload: {
          'id': 'message',
          'kind': 'file',
          'body': 'ciphertext',
          'file_id': 'file',
          'original_name': 'private.zip',
          'content_type': 'application/zip',
          'size_bytes': 23,
          'ciphertext_size_bytes': 67,
          'encryption_mode': 'e2ee',
          'nonce': 'nonce',
          'attachment_format': 'format',
        },
        sentAt: sentAt,
      ),
    );
    final decrypted = message.withBody('cleartext');

    expect(decrypted.body, 'cleartext');
    expect(decrypted.fileId, 'file');
    expect(decrypted.originalName, 'private.zip');
    expect(decrypted.sizeBytes, 23);
    expect(decrypted.ciphertextSizeBytes, 67);
    expect(decrypted.encryptionMode, 'e2ee');
    expect(decrypted.nonce, 'nonce');
    expect(decrypted.attachmentFormat, 'format');
    expect(decrypted.sentAt, sentAt);
  });

  test('retracted direct messages keep participants and time', () {
    final sentAt = DateTime.utc(2026, 7, 15, 12);
    final removed = DirectMessage(
      id: 'message',
      fromUserId: 'sender',
      toUserId: 'recipient',
      kind: 'file',
      body: 'secret',
      fileId: 'file',
      originalName: 'private.zip',
      contentType: 'application/zip',
      sizeBytes: 23,
      ciphertextSizeBytes: 67,
      encryptionMode: 'e2ee',
      nonce: 'nonce',
      attachmentFormat: 'format',
      expiresAt: DateTime.utc(2026, 8),
      sentAt: sentAt,
    ).retracted();

    expect(removed.kind, 'removed');
    expect(removed.body, isEmpty);
    expect(removed.fileId, isEmpty);
    expect(removed.sizeBytes, 0);
    expect(removed.encryptionMode, 'none');
    expect(removed.fromUserId, 'sender');
    expect(removed.toUserId, 'recipient');
    expect(removed.sentAt, sentAt);
  });
}
