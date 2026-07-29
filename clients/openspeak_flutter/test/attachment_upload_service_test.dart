import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/attachment_upload_service.dart';
import 'package:openspeak_flutter/channel_key_controller.dart';
import 'package:openspeak_flutter/device_identity_service.dart';
import 'package:openspeak_flutter/direct_message.dart';
import 'package:openspeak_flutter/openspeak_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Web direct upload keeps encrypted attachment metadata intact',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final identityService = DeviceIdentityService();
      final sender = await identityService.loadOrCreate(
        'srv_upload_sender',
        userId: 'usr_sender',
      );
      final recipient = await identityService.loadOrCreate(
        'srv_upload_recipient',
        userId: 'usr_recipient',
      );
      final api = _UploadApi([
        _device(sender, 'usr_sender'),
        _device(recipient, 'usr_recipient'),
      ]);
      final clear = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 251),
      );
      final directory = await Directory.systemTemp.createTemp(
        'openspeak_upload_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = await File(
        '${directory.path}${Platform.pathSeparator}secret.txt',
      ).writeAsBytes(clear);
      var progress = 0;

      await AttachmentUploadService(identityService).uploadDirect(
        api: api,
        token: 'token',
        serverId: 'srv_upload',
        currentUserId: 'usr_sender',
        peerUserId: 'usr_recipient',
        file: XFile(source.path),
        fileLength: clear.length,
        encryptionMode: 'e2ee',
        identity: sender,
        directMessageKeys: DirectMessageKeyController(identityService),
        onProgress: (sent, _) => progress = sent,
        cancelToken: TransferCancelToken(),
        isWeb: true,
      );

      final recipientEnvelope = api.envelopes.firstWhere(
        (item) => item['recipient_device_id'] == recipient.deviceId,
      );
      final key = await identityService.unwrapChannelKey(
        recipient: recipient,
        channelId: directEncryptionScope(
          'srv_upload',
          'usr_sender',
          'usr_recipient',
        ),
        epochId: api.messageId,
        senderDeviceId: sender.deviceId,
        senderIdentityPublicKey: sender.identityPublicKey,
        ciphertext: recipientEnvelope['ciphertext']!,
      );
      final decrypted = await identityService.decryptAttachmentBytes(
        input: api.uploadedBytes,
        channelKey: key,
        channelId: directEncryptionScope(
          'srv_upload',
          'usr_sender',
          'usr_recipient',
        ),
        epochId: api.messageId,
        nonce: api.nonce,
        plaintextSize: clear.length,
      );

      expect(decrypted, clear);
      expect(api.originalName, 'secret.txt');
      expect(api.encryptionMode, 'e2ee');
      expect(api.plaintextSizeBytes, clear.length);
      expect(api.attachmentFormat, attachmentEncryptionFormatV1);
      expect(api.chunkSize, attachmentEncryptionChunkSize);
      expect(api.envelopes, hasLength(2));
      expect(progress, api.uploadedBytes.length);
    },
  );

  test(
    'channel encryption retries an epoch change with intact metadata',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final identityService = DeviceIdentityService();
      final identity = await identityService.loadOrCreate(
        'srv_upload_empty',
        userId: 'usr_sender',
      );
      final api = _UploadApi(
        const [],
        failFirstChannelUpload: true,
        channelState: ChannelE2EEState(
          epoch: ChannelEpoch(
            id: 'epc_empty',
            channelId: 'chn_empty',
            number: 1,
          ),
          devices: [
            ChannelE2EEDevice(
              id: identity.deviceId,
              userId: 'usr_sender',
              identityPublicKey: identity.identityPublicKey,
              envelopePublicKey: identity.envelopePublicKey,
              hasEnvelope: false,
            ),
          ],
        ),
      );
      final directory = await Directory.systemTemp.createTemp(
        'openspeak_upload_empty_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = await File(
        '${directory.path}${Platform.pathSeparator}empty.bin',
      ).writeAsBytes(const [1]);

      await AttachmentUploadService(identityService).uploadChannel(
        api: api,
        token: 'token',
        channelId: 'chn_empty',
        file: XFile(source.path),
        fileLength: 1,
        image: false,
        encryptionMode: 'e2ee',
        identity: identity,
        channelKeys: ChannelKeyController(identityService),
        onProgress: (_, _) {},
        cancelToken: TransferCancelToken(),
        isWeb: true,
      );

      expect(api.channelEpochId, 'epc_empty');
      expect(api.channelPlaintextSizeBytes, 1);
      expect(api.channelAttachmentFormat, attachmentEncryptionFormatV1);
      expect(api.channelChunkSize, attachmentEncryptionChunkSize);
      expect(api.channelUploadCount, 2);
    },
  );
}

ChannelE2EEDevice _device(E2EEDeviceIdentity identity, String userId) =>
    ChannelE2EEDevice(
      id: identity.deviceId,
      userId: userId,
      identityPublicKey: identity.identityPublicKey,
      envelopePublicKey: identity.envelopePublicKey,
      hasEnvelope: false,
    );

class _UploadApi extends OpenSpeakApi {
  _UploadApi(
    this.devices, {
    this.channelState,
    this.failFirstChannelUpload = false,
  }) : super('http://localhost');

  final List<ChannelE2EEDevice> devices;
  final ChannelE2EEState? channelState;
  final bool failFirstChannelUpload;
  late Uint8List uploadedBytes;
  String originalName = '';
  String encryptionMode = '';
  String messageId = '';
  String nonce = '';
  int plaintextSizeBytes = 0;
  String attachmentFormat = '';
  int chunkSize = 0;
  List<Map<String, String>> envelopes = const [];
  String channelEpochId = '';
  int channelPlaintextSizeBytes = 0;
  String channelAttachmentFormat = '';
  int channelChunkSize = 0;
  int channelUploadCount = 0;

  @override
  Future<List<ChannelE2EEDevice>> getDirectE2EEDevices(
    String token, {
    required String serverId,
    required String toUserId,
  }) async => devices;

  @override
  Future<ChannelE2EEState> getChannelE2EEState(
    String token,
    String channelId, {
    bool media = false,
  }) async => channelState!;

  @override
  Future<List<KeyEnvelope>> listKeyEnvelopes(
    String token, {
    required String channelId,
    required String recipientDeviceId,
    bool media = false,
  }) async => const [];

  @override
  Future<List<KeyEnvelope>> storeKeyEnvelopeBatch(
    String token, {
    required String channelId,
    required String epochId,
    required String senderDeviceId,
    required List<KeyEnvelopeUpload> envelopes,
    bool media = false,
  }) async => const [];

  @override
  Future<ChannelUploadResult> uploadChannelFile(
    String token,
    String channelId,
    XFile file, {
    required String encryptionMode,
    String? originalName,
    String? contentType,
    String epochId = '',
    String nonce = '',
    int plaintextSizeBytes = 0,
    String attachmentFormat = '',
    int chunkSize = 0,
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    channelUploadCount += 1;
    if (failFirstChannelUpload && channelUploadCount == 1) {
      throw OpenSpeakException('频道密钥周期已变化', code: 'epoch_changed');
    }
    channelEpochId = epochId;
    channelPlaintextSizeBytes = plaintextSizeBytes;
    channelAttachmentFormat = attachmentFormat;
    channelChunkSize = chunkSize;
    final bytes = await file.readAsBytes();
    onProgress?.call(bytes.length, bytes.length);
    return ChannelUploadResult(
      file: StoredFile(
        id: 'file_empty',
        originalName: originalName ?? '',
        contentType: contentType ?? '',
        sizeBytes: plaintextSizeBytes,
      ),
      message: ChannelMessage(
        id: 'msg_empty',
        channelId: channelId,
        senderUserId: 'usr_sender',
        senderDisplayName: 'sender',
        kind: 'file',
        encryptionMode: encryptionMode,
        body: '',
        metadata: const {},
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<DirectFile> uploadDirectFile(
    String token,
    String toUserId,
    XFile file, {
    String? originalName,
    String? contentType,
    String encryptionMode = 'none',
    String messageId = '',
    String senderDeviceId = '',
    String nonce = '',
    int plaintextSizeBytes = 0,
    String attachmentFormat = '',
    int chunkSize = 0,
    List<Map<String, String>> directEnvelopes = const [],
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    uploadedBytes = await file.readAsBytes();
    this.originalName = originalName ?? '';
    this.encryptionMode = encryptionMode;
    this.messageId = messageId;
    this.nonce = nonce;
    this.plaintextSizeBytes = plaintextSizeBytes;
    this.attachmentFormat = attachmentFormat;
    this.chunkSize = chunkSize;
    envelopes = directEnvelopes;
    onProgress?.call(uploadedBytes.length, uploadedBytes.length);
    return DirectFile(
      id: 'file_test',
      serverId: 'srv_upload',
      fromUserId: 'usr_sender',
      toUserId: toUserId,
      originalName: this.originalName,
      contentType: contentType ?? '',
      sizeBytes: plaintextSizeBytes,
      expiresAt: null,
    );
  }
}
