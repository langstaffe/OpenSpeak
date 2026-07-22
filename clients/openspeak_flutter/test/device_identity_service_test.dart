import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/device_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('E2EE device keys are real and stable per server and user', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = DeviceIdentityService();

    final first = await service.loadOrCreate('srv_test', userId: 'usr_test');
    final second = await DeviceIdentityService().loadOrCreate(
      'srv_test',
      userId: 'usr_test',
    );

    expect(second.deviceId, first.deviceId);
    expect(second.identitySeed, first.identitySeed);
    expect(second.envelopeSeed, first.envelopeSeed);
    expect(first.deviceId, startsWith('dev_'));
    final identityPublicKey = await (await Ed25519().newKeyPairFromSeed(
      first.identitySeed,
    )).extractPublicKey();
    final envelopePublicKey = await (await X25519().newKeyPairFromSeed(
      first.envelopeSeed,
    )).extractPublicKey();
    expect(
      base64Url.decode(base64Url.normalize(first.identityPublicKey)),
      identityPublicKey.bytes,
    );
    expect(
      base64Url.decode(base64Url.normalize(first.envelopePublicKey)),
      envelopePublicKey.bytes,
    );
  });

  test('direct message ids are random protocol ids', () {
    final service = DeviceIdentityService();
    final first = service.newDirectMessageId();
    final second = service.newDirectMessageId();
    expect(first, matches(RegExp(r'^dm_[0-9a-f]{24}$')));
    expect(second, isNot(first));
  });

  test('corrupt stored identity is replaced', () async {
    FlutterSecureStorage.setMockInitialValues({
      'openspeak.e2ee.device.srv_corrupt': jsonEncode({
        'version': 1,
        'device_id': 'broken',
      }),
    });
    final identity = await DeviceIdentityService().loadOrCreate(
      'srv_corrupt',
      userId: 'usr_test',
    );
    expect(identity.deviceId, matches(RegExp(r'^dev_[0-9a-f]{32}$')));
  });

  test('owner identity switch does not reuse a member device', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final legacy = await DeviceIdentityService().loadOrCreate(
      'srv_seed',
      userId: 'usr_seed',
    );
    FlutterSecureStorage.setMockInitialValues({
      'openspeak.e2ee.device.srv_switch': jsonEncode({
        'version': 1,
        'device_id': legacy.deviceId,
        'identity_seed': base64Url.encode(legacy.identitySeed),
        'identity_public_key': legacy.identityPublicKey,
        'envelope_seed': base64Url.encode(legacy.envelopeSeed),
        'envelope_public_key': legacy.envelopePublicKey,
      }),
    });

    final owner = await DeviceIdentityService().loadOrCreate(
      'srv_switch',
      userId: 'usr_owner',
      migrateLegacyIdentity: false,
    );
    final member = await DeviceIdentityService().loadOrCreate(
      'srv_switch',
      userId: 'usr_member',
    );

    expect(owner.deviceId, isNot(legacy.deviceId));
    expect(member.deviceId, legacy.deviceId);
  });

  test('channel envelopes and text round-trip and reject tampering', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = DeviceIdentityService();
    final sender = await service.loadOrCreate(
      'srv_sender',
      userId: 'usr_sender',
    );
    final recipient = await service.loadOrCreate(
      'srv_recipient',
      userId: 'usr_recipient',
    );
    final channelKey = await service.newChannelKey();
    final envelope = await service.wrapChannelKey(
      sender: sender,
      channelId: 'chn_test',
      epochId: 'epc_test',
      recipientDeviceId: recipient.deviceId,
      recipientEnvelopePublicKey: recipient.envelopePublicKey,
      channelKey: channelKey,
    );
    final unwrapped = await service.unwrapChannelKey(
      recipient: recipient,
      channelId: 'chn_test',
      epochId: 'epc_test',
      senderDeviceId: sender.deviceId,
      senderIdentityPublicKey: sender.identityPublicKey,
      ciphertext: envelope,
    );
    expect(await unwrapped.extractBytes(), await channelKey.extractBytes());

    final encrypted = await service.encryptChannelText(
      channelKey: unwrapped,
      channelId: 'chn_test',
      epochId: 'epc_test',
      cleartext: '只有客户端能看到',
    );
    expect(encrypted.body, isNot(contains('只有客户端能看到')));
    expect(
      await service.decryptChannelText(
        channelKey: unwrapped,
        channelId: 'chn_test',
        epochId: 'epc_test',
        body: encrypted.body,
        nonce: encrypted.nonce,
      ),
      '只有客户端能看到',
    );
    await expectLater(
      service.decryptChannelText(
        channelKey: unwrapped,
        channelId: 'chn_other',
        epochId: 'epc_test',
        body: encrypted.body,
        nonce: encrypted.nonce,
      ),
      throwsA(anything),
    );
    await expectLater(
      service.unwrapChannelKey(
        recipient: recipient,
        channelId: 'chn_other',
        epochId: 'epc_test',
        senderDeviceId: sender.deviceId,
        senderIdentityPublicKey: sender.identityPublicKey,
        ciphertext: envelope,
      ),
      throwsA(anything),
    );
  });

  test('attachment files decrypt fully and by plaintext range', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = DeviceIdentityService();
    final key = await service.newChannelKey();
    final clear = Uint8List.fromList(
      List<int>.generate(
        attachmentEncryptionChunkSize * 2 + 123,
        (index) => index % 251,
      ),
    );
    final dir = await Directory.systemTemp.createTemp('openspeak_e2ee_test_');
    addTearDown(() => dir.delete(recursive: true));
    final input = File('${dir.path}/input.bin');
    final encryptedFile = File('${dir.path}/encrypted.bin');
    final output = File('${dir.path}/output.bin');
    await input.writeAsBytes(clear);
    final encrypted = await service.encryptAttachmentFile(
      input: input,
      output: encryptedFile,
      channelKey: key,
      channelId: 'chn_test',
      epochId: 'epc_test',
    );
    expect(
      encrypted.ciphertextSize,
      attachmentEncryptionHeaderSize + clear.length + 3 * 16,
    );
    await service.decryptAttachmentFile(
      input: encryptedFile,
      output: output,
      channelKey: key,
      channelId: 'chn_test',
      epochId: 'epc_test',
      nonce: encrypted.nonce,
      plaintextSize: clear.length,
    );
    expect(await output.readAsBytes(), clear);

    Future<Uint8List> readRange(int start, int endInclusive) async {
      final handle = await encryptedFile.open();
      await handle.setPosition(start);
      final bytes = await handle.read(endInclusive - start + 1);
      await handle.close();
      return bytes;
    }

    const start = attachmentEncryptionChunkSize - 17;
    const end = attachmentEncryptionChunkSize + 31;
    expect(
      await service.decryptAttachmentRange(
        readCipherRange: readRange,
        channelKey: key,
        channelId: 'chn_test',
        epochId: 'epc_test',
        nonce: encrypted.nonce,
        plaintextSize: clear.length,
        start: start,
        endInclusive: end,
      ),
      clear.sublist(start, end + 1),
    );
    await expectLater(
      service.decryptAttachmentRange(
        readCipherRange: readRange,
        channelKey: key,
        channelId: 'chn_other',
        epochId: 'epc_test',
        nonce: encrypted.nonce,
        plaintextSize: clear.length,
        start: 0,
        endInclusive: 10,
      ),
      throwsA(anything),
    );
  });

  test('attachment bytes use the same authenticated chunk format', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = DeviceIdentityService();
    final key = await service.newChannelKey();
    final clear = Uint8List.fromList(
      List<int>.generate(
        attachmentEncryptionChunkSize + 37,
        (index) => index % 251,
      ),
    );
    final encrypted = await service.encryptAttachmentBytes(
      input: clear,
      channelKey: key,
      channelId: 'chn_web',
      epochId: 'epc_web',
    );
    expect(
      encrypted.bytes.length,
      attachmentEncryptionHeaderSize + clear.length + 2 * 16,
    );
    expect(
      await service.decryptAttachmentBytes(
        input: encrypted.bytes,
        channelKey: key,
        channelId: 'chn_web',
        epochId: 'epc_web',
        nonce: encrypted.nonce,
        plaintextSize: clear.length,
      ),
      clear,
    );
    final tampered = Uint8List.fromList(encrypted.bytes)..last ^= 1;
    await expectLater(
      service.decryptAttachmentBytes(
        input: tampered,
        channelKey: key,
        channelId: 'chn_web',
        epochId: 'epc_web',
        nonce: encrypted.nonce,
        plaintextSize: clear.length,
      ),
      throwsA(anything),
    );
  });
}
