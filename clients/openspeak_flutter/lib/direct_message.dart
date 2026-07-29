import 'package:cryptography/cryptography.dart';

import 'device_identity_service.dart';
import 'openspeak_api.dart';

String directEncryptionScope(
  String serverId,
  String firstUserId,
  String secondUserId,
) {
  final users = [firstUserId, secondUserId]..sort();
  return 'direct:$serverId:${users[0]}:${users[1]}';
}

typedef PreparedDirectEncryption = ({
  String serverId,
  String messageId,
  String senderDeviceId,
  SecretKeyData key,
  List<Map<String, String>> envelopes,
});

class DirectMessageKeyController {
  DirectMessageKeyController(this.deviceIdentity);

  final DeviceIdentityService deviceIdentity;
  final _keys = <String, SecretKeyData>{};

  SecretKeyData? keyFor(String messageId) => _keys[messageId];

  void remove(String messageId) => _keys.remove(messageId);

  void clear() => _keys.clear();

  Future<PreparedDirectEncryption> prepare({
    required OpenSpeakApi api,
    required String token,
    required String serverId,
    required String currentUserId,
    required String peerUserId,
    required E2EEDeviceIdentity identity,
  }) async {
    final devices = await api.getDirectE2EEDevices(
      token,
      serverId: serverId,
      toUserId: peerUserId,
    );
    if (!devices.any((item) => item.id == identity.deviceId) ||
        !devices.any((item) => item.userId == peerUserId)) {
      throw OpenSpeakException('私聊设备已变化，请重试');
    }
    final messageId = deviceIdentity.newDirectMessageId();
    final key = await deviceIdentity.newChannelKey();
    final scope = directEncryptionScope(serverId, currentUserId, peerUserId);
    final envelopes = await Future.wait(
      devices.map((recipient) async {
        final ciphertext = await deviceIdentity.wrapChannelKey(
          sender: identity,
          channelId: scope,
          epochId: messageId,
          recipientDeviceId: recipient.id,
          recipientEnvelopePublicKey: recipient.envelopePublicKey,
          channelKey: key,
        );
        return <String, String>{
          'algorithm': 'openspeak-envelope-v1',
          'recipient_user_id': recipient.userId,
          'recipient_device_id': recipient.id,
          'ciphertext': ciphertext,
        };
      }),
    );
    return (
      serverId: serverId,
      messageId: messageId,
      senderDeviceId: identity.deviceId,
      key: key,
      envelopes: envelopes,
    );
  }

  Future<SecretKeyData> unwrapAndCache({
    required E2EEDeviceIdentity? identity,
    required RealtimeEvent event,
  }) async {
    final messageId = event.payload['id'] as String? ?? '';
    final senderDeviceId = event.payload['sender_device_id'] as String? ?? '';
    final senderIdentityPublicKey =
        event.payload['sender_identity_public_key'] as String? ?? '';
    final rawEnvelopes = event.payload['envelopes'];
    if (identity == null || rawEnvelopes is! List) {
      throw const FormatException('missing direct key envelope');
    }
    Map<String, dynamic>? envelope;
    for (final raw in rawEnvelopes) {
      if (raw is Map && raw['recipient_device_id'] == identity.deviceId) {
        envelope = raw.cast<String, dynamic>();
        break;
      }
    }
    if (envelope == null || envelope['algorithm'] != 'openspeak-envelope-v1') {
      throw const FormatException('direct key envelope not found');
    }
    final key = await deviceIdentity.unwrapChannelKey(
      recipient: identity,
      channelId: directEncryptionScope(
        event.serverId,
        event.fromUser,
        event.toUser,
      ),
      epochId: messageId,
      senderDeviceId: senderDeviceId,
      senderIdentityPublicKey: senderIdentityPublicKey,
      ciphertext: envelope['ciphertext'] as String? ?? '',
    );
    _keys[messageId] = key;
    return key;
  }
}

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
