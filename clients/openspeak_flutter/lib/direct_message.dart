import 'openspeak_api.dart';

class DirectMessage {
  DirectMessage({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.kind,
    required this.body,
    required this.fileId,
    required this.originalName,
    required this.contentType,
    required this.sizeBytes,
    this.ciphertextSizeBytes = 0,
    this.encryptionMode = 'none',
    this.nonce = '',
    this.attachmentFormat = '',
    required this.expiresAt,
    required this.sentAt,
  });

  final String id;
  final String fromUserId;
  final String toUserId;
  final String kind;
  final String body;
  final String fileId;
  final String originalName;
  final String contentType;
  final int sizeBytes;
  final int ciphertextSizeBytes;
  final String encryptionMode;
  final String nonce;
  final String attachmentFormat;
  final DateTime? expiresAt;
  final DateTime? sentAt;

  factory DirectMessage.fromEvent(RealtimeEvent event) {
    final kind = event.payload['kind'] as String? ?? 'text';
    final originalName = event.payload['original_name'] as String? ?? '';
    return DirectMessage(
      id: event.payload['id'] as String? ?? '',
      fromUserId: event.fromUser,
      toUserId: event.toUser,
      kind: kind,
      body: event.payload['body'] as String? ?? originalName,
      fileId: event.payload['file_id'] as String? ?? '',
      originalName: originalName,
      contentType: event.payload['content_type'] as String? ?? '',
      sizeBytes: event.payload['size_bytes'] as int? ?? 0,
      ciphertextSizeBytes: event.payload['ciphertext_size_bytes'] as int? ?? 0,
      encryptionMode: event.payload['encryption_mode'] as String? ?? 'none',
      nonce: event.payload['nonce'] as String? ?? '',
      attachmentFormat: event.payload['attachment_format'] as String? ?? '',
      expiresAt: DateTime.tryParse(
        event.payload['expires_at'] as String? ?? '',
      ),
      sentAt: event.sentAt,
    );
  }

  DirectMessage withBody(String cleartext) => DirectMessage(
    id: id,
    fromUserId: fromUserId,
    toUserId: toUserId,
    kind: kind,
    body: cleartext,
    fileId: fileId,
    originalName: originalName,
    contentType: contentType,
    sizeBytes: sizeBytes,
    ciphertextSizeBytes: ciphertextSizeBytes,
    encryptionMode: encryptionMode,
    nonce: nonce,
    attachmentFormat: attachmentFormat,
    expiresAt: expiresAt,
    sentAt: sentAt,
  );

  DirectMessage retracted() => DirectMessage(
    id: id,
    fromUserId: fromUserId,
    toUserId: toUserId,
    kind: 'removed',
    body: '',
    fileId: '',
    originalName: '',
    contentType: '',
    sizeBytes: 0,
    ciphertextSizeBytes: 0,
    encryptionMode: 'none',
    nonce: '',
    attachmentFormat: '',
    expiresAt: null,
    sentAt: sentAt,
  );
}
