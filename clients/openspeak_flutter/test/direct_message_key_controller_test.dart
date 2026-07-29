import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/device_identity_service.dart';
import 'package:openspeak_flutter/direct_message.dart';
import 'package:openspeak_flutter/openspeak_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('prepares, unwraps, and caches direct message keys', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = DeviceIdentityService();
    final sender = await service.loadOrCreate(
      'srv_direct_sender',
      userId: 'usr_sender',
    );
    final recipient = await service.loadOrCreate(
      'srv_direct_recipient',
      userId: 'usr_recipient',
    );
    final api = _DirectDevicesApi([
      _device(sender, 'usr_sender'),
      _device(recipient, 'usr_recipient'),
    ]);
    final controller = DirectMessageKeyController(service);

    final prepared = await controller.prepare(
      api: api,
      token: 'token',
      serverId: 'srv_direct',
      currentUserId: 'usr_sender',
      peerUserId: 'usr_recipient',
      identity: sender,
    );
    final event = RealtimeEvent(
      type: 'direct.message',
      serverId: prepared.serverId,
      channelId: '',
      fromUser: 'usr_sender',
      toUser: 'usr_recipient',
      payload: {
        'id': prepared.messageId,
        'sender_device_id': prepared.senderDeviceId,
        'sender_identity_public_key': sender.identityPublicKey,
        'envelopes': prepared.envelopes,
      },
      sentAt: null,
    );
    final unwrapped = await controller.unwrapAndCache(
      identity: recipient,
      event: event,
    );

    expect(api.requests, 1);
    expect(prepared.envelopes, hasLength(2));
    expect(await unwrapped.extractBytes(), await prepared.key.extractBytes());
    expect(
      await controller.keyFor(prepared.messageId)!.extractBytes(),
      await prepared.key.extractBytes(),
    );
    controller.clear();
    expect(controller.keyFor(prepared.messageId), isNull);
  });

  test('rejects direct encryption when the peer has no device', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = DeviceIdentityService();
    final sender = await service.loadOrCreate(
      'srv_direct_missing',
      userId: 'usr_sender',
    );
    final controller = DirectMessageKeyController(service);

    await expectLater(
      controller.prepare(
        api: _DirectDevicesApi([_device(sender, 'usr_sender')]),
        token: 'token',
        serverId: 'srv_direct',
        currentUserId: 'usr_sender',
        peerUserId: 'usr_recipient',
        identity: sender,
      ),
      throwsA(
        isA<OpenSpeakException>().having(
          (error) => error.message,
          'message',
          '私聊设备已变化，请重试',
        ),
      ),
    );
  });
}

ChannelE2EEDevice _device(E2EEDeviceIdentity identity, String userId) =>
    ChannelE2EEDevice(
      id: identity.deviceId,
      userId: userId,
      identityPublicKey: identity.identityPublicKey,
      envelopePublicKey: identity.envelopePublicKey,
      hasEnvelope: false,
    );

class _DirectDevicesApi extends OpenSpeakApi {
  _DirectDevicesApi(this.devices) : super('http://localhost');

  final List<ChannelE2EEDevice> devices;
  int requests = 0;

  @override
  Future<List<ChannelE2EEDevice>> getDirectE2EEDevices(
    String token, {
    required String serverId,
    required String toUserId,
  }) async {
    requests += 1;
    return devices;
  }
}
