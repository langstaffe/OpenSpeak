import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/channel_key_controller.dart';
import 'package:openspeak_flutter/device_identity_service.dart';
import 'package:openspeak_flutter/openspeak_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('coalesces concurrent channel key loads', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final identity = await DeviceIdentityService().loadOrCreate(
      'srv_channel_key',
      userId: 'usr_channel_key',
    );
    final state = _stateFor(identity);
    final api = _ChannelKeyApi(state);
    final controller = ChannelKeyController(DeviceIdentityService());

    final keys = await Future.wait([
      controller.ensureKey(
        api: api,
        token: 'token',
        identity: identity,
        channelId: 'chn_test',
      ),
      controller.ensureKey(
        api: api,
        token: 'token',
        identity: identity,
        channelId: 'chn_test',
      ),
    ]);

    expect(api.stateCalls, 1);
    expect(api.envelopeListCalls, 1);
    expect(api.envelopeStoreCalls, 1);
    expect(await keys.first.extractBytes(), await keys.last.extractBytes());
  });

  test('reset cancels an in-flight channel key load', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final identity = await DeviceIdentityService().loadOrCreate(
      'srv_channel_key_reset',
      userId: 'usr_channel_key_reset',
    );
    final api = _ChannelKeyApi(_stateFor(identity), pauseState: true);
    final controller = ChannelKeyController(DeviceIdentityService());
    final load = controller.ensureKey(
      api: api,
      token: 'token',
      identity: identity,
      channelId: 'chn_test',
    );
    await api.stateRequested.future;

    controller.resetCoordination();
    api.releaseState.complete();

    await expectLater(
      load,
      throwsA(
        isA<OpenSpeakException>().having(
          (error) => error.message,
          'message',
          '频道密钥请求已取消',
        ),
      ),
    );
  });
}

ChannelE2EEState _stateFor(E2EEDeviceIdentity identity) => ChannelE2EEState(
  epoch: ChannelEpoch(id: 'epc_test', channelId: 'chn_test', number: 1),
  devices: [
    ChannelE2EEDevice(
      id: identity.deviceId,
      userId: 'usr_test',
      identityPublicKey: identity.identityPublicKey,
      envelopePublicKey: identity.envelopePublicKey,
      hasEnvelope: false,
    ),
  ],
);

class _ChannelKeyApi extends OpenSpeakApi {
  _ChannelKeyApi(this.state, {this.pauseState = false})
    : super('http://localhost');

  final ChannelE2EEState state;
  final bool pauseState;
  final stateRequested = Completer<void>();
  final releaseState = Completer<void>();
  int stateCalls = 0;
  int envelopeListCalls = 0;
  int envelopeStoreCalls = 0;

  @override
  Future<ChannelE2EEState> getChannelE2EEState(
    String token,
    String channelId, {
    bool media = false,
  }) async {
    stateCalls += 1;
    if (pauseState) {
      stateRequested.complete();
      await releaseState.future;
    }
    return state;
  }

  @override
  Future<List<KeyEnvelope>> listKeyEnvelopes(
    String token, {
    required String channelId,
    required String recipientDeviceId,
    bool media = false,
  }) async {
    envelopeListCalls += 1;
    return [];
  }

  @override
  Future<List<KeyEnvelope>> storeKeyEnvelopeBatch(
    String token, {
    required String channelId,
    required String epochId,
    required String senderDeviceId,
    required List<KeyEnvelopeUpload> envelopes,
    bool media = false,
  }) async {
    envelopeStoreCalls += 1;
    return [];
  }
}
