import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/owner_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('owner device keys sign Ed25519 challenges', () async {
    final service = OwnerIdentityService();
    final device = await service.createDeviceKey();
    expect(device.deviceId, startsWith('odev_'));
    final challenge = base64Url
        .encode(List<int>.generate(32, (index) => 255 - index))
        .replaceAll('=', '');
    final signature = Signature(
      base64Url.decode(
        base64Url.normalize(await service.sign(device, challenge)),
      ),
      publicKey: SimplePublicKey(
        base64Url.decode(base64Url.normalize(device.publicKey)),
        type: KeyPairType.ed25519,
      ),
    );
    expect(
      await Ed25519().verify(
        base64Url.decode(base64Url.normalize(challenge)),
        signature: signature,
      ),
      isTrue,
    );
  });

  test(
    'owner credential hint is absent for ordinary users by default',
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = OwnerIdentityService();

      expect(await service.hasCredentialHint('srv_normal'), isFalse);
    },
  );

  test('owner credential hint reads non-sensitive server index', () async {
    SharedPreferences.setMockInitialValues({
      'openspeak.ownerCredentialServers.v1': jsonEncode(['srv_owner']),
    });
    final service = OwnerIdentityService();

    expect(await service.hasCredentialHint('srv_owner'), isTrue);
    expect(await service.hasCredentialHint('srv_other'), isFalse);
  });
}
