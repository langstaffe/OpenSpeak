import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OwnerDeviceKey {
  OwnerDeviceKey({
    required this.deviceId,
    required this.seed,
    required this.publicKey,
  });

  final String deviceId;
  final Uint8List seed;
  final String publicKey;
}

class StoredOwnerCredential extends OwnerDeviceKey {
  StoredOwnerCredential({
    required super.deviceId,
    required super.seed,
    required super.publicKey,
  });
}

class OwnerIdentityService {
  static const _credentialServersKey = 'openspeak.ownerCredentialServers.v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      accountName: 'OpenSpeak',
      useDataProtectionKeyChain: false,
    ),
  );

  final Ed25519 _algorithm = Ed25519();
  String _key(String serverId) => 'openspeak.owner.device.$serverId';

  Future<OwnerDeviceKey> createDeviceKey() async {
    final keyPair = await _algorithm.newKeyPair();
    final seed = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = await keyPair.extractPublicKey();
    return OwnerDeviceKey(
      deviceId: _newDeviceId(),
      seed: seed,
      publicKey: base64Url.encode(publicKey.bytes).replaceAll('=', ''),
    );
  }

  Future<void> saveCredential(String serverId, OwnerDeviceKey key) async {
    await _storage.write(
      key: _key(serverId),
      value: jsonEncode({
        'device_id': key.deviceId,
        'seed': base64Url.encode(key.seed),
        'public_key': key.publicKey,
      }),
    );
    await _setCredentialHint(serverId, true);
  }

  Future<StoredOwnerCredential?> loadCredential(String serverId) async {
    final raw = await _storage.read(key: _key(serverId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return StoredOwnerCredential(
        deviceId: json['device_id'] as String,
        seed: Uint8List.fromList(base64Url.decode(json['seed'] as String)),
        publicKey: json['public_key'] as String,
      );
    } catch (_) {
      await deleteCredential(serverId);
      return null;
    }
  }

  Future<bool> hasCredentialHint(String serverId) async {
    final servers = await _credentialHintServers();
    return servers.contains(serverId);
  }

  Future<void> deleteCredential(String serverId) async {
    try {
      await _storage.delete(key: _key(serverId));
    } finally {
      await _setCredentialHint(serverId, false);
    }
  }

  Future<String> sign(OwnerDeviceKey key, String challenge) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(key.seed);
    final signature = await _algorithm.sign(
      base64Url.decode(base64Url.normalize(challenge)),
      keyPair: keyPair,
    );
    return base64Url.encode(signature.bytes).replaceAll('=', '');
  }

  String _newDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final value = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
    return 'odev_${value.join()}';
  }

  Future<Set<String>> _credentialHintServers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_credentialServersKey);
    if (raw == null || raw.trim().isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet();
    } catch (_) {
      await prefs.remove(_credentialServersKey);
      return <String>{};
    }
  }

  Future<void> _setCredentialHint(String serverId, bool present) async {
    final trimmed = serverId.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final servers = await _credentialHintServers();
    if (present) {
      servers.add(trimmed);
    } else {
      servers.remove(trimmed);
    }
    if (servers.isEmpty) {
      await prefs.remove(_credentialServersKey);
      return;
    }
    await prefs.setString(_credentialServersKey, jsonEncode(servers.toList()));
  }
}
