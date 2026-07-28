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

class DirectMessageStore {
  final _messages = <String, List<DirectMessage>>{};
  final _pending = <String, List<DirectMessage>>{};
  final _expiredFileIds = <String>{};

  List<DirectMessage> messagesFor(String userId) =>
      _messages[userId] ?? const [];

  void add(String userId, DirectMessage message) {
    _messages.putIfAbsent(userId, () => []).add(message);
  }

  List<String> addIncoming(
    String userId,
    DirectMessage message, {
    required bool pending,
    required bool Function(DirectMessage message) removeWhere,
  }) {
    final messages = (pending ? _pending : _messages).putIfAbsent(
      userId,
      () => [],
    );
    final removedIds = <String>[];
    messages.removeWhere((item) {
      if (!removeWhere(item)) return false;
      removedIds.add(item.id);
      return true;
    });
    if (!messages.any((item) => item.id == message.id)) {
      messages.add(message);
    }
    return removedIds;
  }

  void remove(String userId, String messageId) {
    _messages[userId]?.removeWhere((message) => message.id == messageId);
  }

  void markRetracted(String userId, String messageId) {
    for (final messages in [_messages[userId], _pending[userId]]) {
      if (messages == null) continue;
      final index = messages.indexWhere((message) => message.id == messageId);
      if (index >= 0) messages[index] = messages[index].retracted();
    }
  }

  void mergePending(String userId) {
    final pending = _pending.remove(userId);
    if (pending == null || pending.isEmpty) return;
    final messages = _messages.putIfAbsent(userId, () => []);
    for (final message in pending) {
      if (!messages.any((item) => item.id == message.id)) {
        messages.add(message);
      }
    }
    messages.sort(
      (a, b) => (a.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
        b.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
  }

  void markFileExpired(String fileId) {
    if (fileId.isNotEmpty) _expiredFileIds.add(fileId);
  }

  bool isFileExpired(String fileId) => _expiredFileIds.contains(fileId);

  void reset() {
    _messages.clear();
    _pending.clear();
    _expiredFileIds.clear();
  }
}
