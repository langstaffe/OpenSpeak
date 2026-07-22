import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class E2EEDeviceIdentity {
  E2EEDeviceIdentity({
    required this.deviceId,
    required this.identitySeed,
    required this.identityPublicKey,
    required this.envelopeSeed,
    required this.envelopePublicKey,
  });

  final String deviceId;
  final Uint8List identitySeed;
  final String identityPublicKey;
  final Uint8List envelopeSeed;
  final String envelopePublicKey;
}

class EncryptedChannelText {
  EncryptedChannelText({required this.body, required this.nonce});

  final String body;
  final String nonce;
}

const attachmentEncryptionFormatV1 = 'openspeak-attachment-v1';
const attachmentEncryptionChunkSize = 64 * 1024;
const attachmentEncryptionHeaderSize = 28;
const _attachmentMagic = <int>[0x4f, 0x53, 0x41, 0x54, 0x54, 0x41, 0x43, 0x31];

class AttachmentEncryptionResult {
  AttachmentEncryptionResult({
    required this.file,
    required this.nonce,
    required this.plaintextSize,
    required this.ciphertextSize,
  });

  final File file;
  final String nonce;
  final int plaintextSize;
  final int ciphertextSize;
}

class AttachmentEncryptionBytesResult {
  AttachmentEncryptionBytesResult({
    required this.bytes,
    required this.nonce,
    required this.plaintextSize,
  });

  final Uint8List bytes;
  final String nonce;
  final int plaintextSize;
}

class DeviceIdentityService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      accountName: 'OpenSpeak',
      useDataProtectionKeyChain: false,
    ),
  );

  final Ed25519 _identityAlgorithm = Ed25519();
  final X25519 _envelopeAlgorithm = X25519();
  final Hkdf _envelopeKdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final AesGcm _cipher = AesGcm.with256bits();

  String _key(String serverId, String userId) =>
      'openspeak.e2ee.device.$serverId.$userId';

  String _legacyKey(String serverId) => 'openspeak.e2ee.device.$serverId';

  Future<E2EEDeviceIdentity> loadOrCreate(
    String serverId, {
    required String userId,
    bool migrateLegacyIdentity = true,
  }) async {
    final key = _key(serverId, userId);
    final raw = await _storage.read(key: key);
    if (raw != null && raw.isNotEmpty) {
      try {
        return await _decode(raw);
      } catch (_) {
        await _storage.delete(key: key);
      }
    }

    if (migrateLegacyIdentity) {
      final legacyKey = _legacyKey(serverId);
      final legacyRaw = await _storage.read(key: legacyKey);
      if (legacyRaw != null && legacyRaw.isNotEmpty) {
        try {
          final identity = await _decode(legacyRaw);
          await _storage.write(key: key, value: legacyRaw);
          await _storage.delete(key: legacyKey);
          return identity;
        } catch (_) {
          await _storage.delete(key: legacyKey);
        }
      }
    }

    final identity = await _identityAlgorithm.newKeyPair();
    final identityPublicKey = await identity.extractPublicKey();
    final envelope = await _envelopeAlgorithm.newKeyPair();
    final envelopePublicKey = await envelope.extractPublicKey();
    final created = E2EEDeviceIdentity(
      deviceId: _newDeviceId(),
      identitySeed: Uint8List.fromList(await identity.extractPrivateKeyBytes()),
      identityPublicKey: _encode(identityPublicKey.bytes),
      envelopeSeed: Uint8List.fromList(await envelope.extractPrivateKeyBytes()),
      envelopePublicKey: _encode(envelopePublicKey.bytes),
    );
    await _storage.write(key: key, value: _encodeIdentity(created));
    return created;
  }

  Future<SecretKeyData> newChannelKey() async =>
      SecretKeyData(await (await _cipher.newSecretKey()).extractBytes());

  String newDirectMessageId() =>
      'dm_${_randomBytes(12).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';

  Future<String> wrapChannelKey({
    required E2EEDeviceIdentity sender,
    required String channelId,
    required String epochId,
    required String recipientDeviceId,
    required String recipientEnvelopePublicKey,
    required SecretKey channelKey,
  }) async {
    final ephemeral = await _envelopeAlgorithm.newKeyPair();
    final ephemeralPublicKey = await ephemeral.extractPublicKey();
    final sharedSecret = await _checkedSharedSecret(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        _decodeBytes(recipientEnvelopePublicKey),
        type: KeyPairType.x25519,
      ),
    );
    final salt = _randomBytes(32);
    final context = _envelopeContext(
      channelId,
      epochId,
      sender.deviceId,
      recipientDeviceId,
    );
    final wrappingKey = await _envelopeKdf.deriveKey(
      secretKey: sharedSecret,
      nonce: salt,
      info: context,
    );
    final box = await _cipher.encrypt(
      await channelKey.extractBytes(),
      secretKey: wrappingKey,
      aad: context,
    );
    final fields = <Object>[
      1,
      _encode(ephemeralPublicKey.bytes),
      _encode(salt),
      _encode(box.nonce),
      _encode(box.cipherText),
      _encode(box.mac.bytes),
    ];
    final signature = await _identityAlgorithm.sign(
      _signedEnvelope(context, fields),
      keyPair: await _identityAlgorithm.newKeyPairFromSeed(sender.identitySeed),
    );
    return jsonEncode({
      'v': fields[0],
      'epk': fields[1],
      'salt': fields[2],
      'nonce': fields[3],
      'ciphertext': fields[4],
      'mac': fields[5],
      'signature': _encode(signature.bytes),
    });
  }

  Future<SecretKeyData> unwrapChannelKey({
    required E2EEDeviceIdentity recipient,
    required String channelId,
    required String epochId,
    required String senderDeviceId,
    required String senderIdentityPublicKey,
    required String ciphertext,
  }) async {
    final value = jsonDecode(ciphertext) as Map<String, dynamic>;
    final fields = <Object>[
      value['v'] as int,
      value['epk'] as String,
      value['salt'] as String,
      value['nonce'] as String,
      value['ciphertext'] as String,
      value['mac'] as String,
    ];
    if (fields[0] != 1) throw const FormatException('unsupported envelope');
    final context = _envelopeContext(
      channelId,
      epochId,
      senderDeviceId,
      recipient.deviceId,
    );
    final signature = Signature(
      _decodeBytes(value['signature'] as String),
      publicKey: SimplePublicKey(
        _decodeBytes(senderIdentityPublicKey),
        type: KeyPairType.ed25519,
      ),
    );
    if (!await _identityAlgorithm.verify(
      _signedEnvelope(context, fields),
      signature: signature,
    )) {
      throw const FormatException('invalid envelope signature');
    }
    final sharedSecret = await _checkedSharedSecret(
      keyPair: await _envelopeAlgorithm.newKeyPairFromSeed(
        recipient.envelopeSeed,
      ),
      remotePublicKey: SimplePublicKey(
        _decodeBytes(fields[1] as String),
        type: KeyPairType.x25519,
      ),
    );
    final wrappingKey = await _envelopeKdf.deriveKey(
      secretKey: sharedSecret,
      nonce: _decodeBytes(fields[2] as String),
      info: context,
    );
    final clear = await _cipher.decrypt(
      SecretBox(
        _decodeBytes(fields[4] as String),
        nonce: _decodeBytes(fields[3] as String),
        mac: Mac(_decodeBytes(fields[5] as String)),
      ),
      secretKey: wrappingKey,
      aad: context,
    );
    if (clear.length != 32) throw const FormatException('invalid channel key');
    return SecretKeyData(clear);
  }

  Future<EncryptedChannelText> encryptChannelText({
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    required String cleartext,
  }) async {
    final box = await _cipher.encrypt(
      utf8.encode(cleartext),
      secretKey: channelKey,
      aad: _messageContext(channelId, epochId),
    );
    return EncryptedChannelText(
      body: _encode([...box.cipherText, ...box.mac.bytes]),
      nonce: _encode(box.nonce),
    );
  }

  Future<String> decryptChannelText({
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    required String body,
    required String nonce,
  }) async {
    final payload = _decodeBytes(body);
    if (payload.length < 16) throw const FormatException('invalid ciphertext');
    final clear = await _cipher.decrypt(
      SecretBox(
        payload.sublist(0, payload.length - 16),
        nonce: _decodeBytes(nonce),
        mac: Mac(payload.sublist(payload.length - 16)),
      ),
      secretKey: channelKey,
      aad: _messageContext(channelId, epochId),
    );
    return utf8.decode(clear);
  }

  Future<AttachmentEncryptionResult> encryptAttachmentFile({
    required File input,
    required File output,
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    void Function(int processed, int total)? onProgress,
    void Function()? checkCancelled,
  }) async {
    final plaintextSize = await input.length();
    if (plaintextSize <= 0) {
      throw const FormatException('attachment is empty');
    }
    final noncePrefix = Uint8List.fromList(_randomBytes(8));
    final header = ByteData(attachmentEncryptionHeaderSize)
      ..buffer.asUint8List().setRange(0, 8, _attachmentMagic)
      ..setUint32(8, attachmentEncryptionChunkSize, Endian.big)
      ..setUint64(12, plaintextSize, Endian.big)
      ..buffer.asUint8List().setRange(20, 28, noncePrefix);
    await output.parent.create(recursive: true);
    final source = await input.open();
    final destination = await output.open(mode: FileMode.write);
    var processed = 0;
    var index = 0;
    try {
      await destination.writeFrom(header.buffer.asUint8List());
      while (processed < plaintextSize) {
        checkCancelled?.call();
        final clear = await source.read(
          min(attachmentEncryptionChunkSize, plaintextSize - processed),
        );
        if (clear.isEmpty) throw const FormatException('attachment truncated');
        final nonce = _attachmentNonce(noncePrefix, index);
        final box = await _cipher.encrypt(
          clear,
          secretKey: channelKey,
          nonce: nonce,
          aad: _attachmentContext(channelId, epochId, plaintextSize, index),
        );
        await destination.writeFrom([...box.cipherText, ...box.mac.bytes]);
        processed += clear.length;
        index += 1;
        onProgress?.call(processed, plaintextSize);
      }
    } catch (_) {
      await source.close();
      await destination.close();
      if (await output.exists()) await output.delete();
      rethrow;
    }
    await source.close();
    await destination.close();
    return AttachmentEncryptionResult(
      file: output,
      nonce: _encode(noncePrefix),
      plaintextSize: plaintextSize,
      ciphertextSize: await output.length(),
    );
  }

  Future<AttachmentEncryptionBytesResult> encryptAttachmentBytes({
    required Uint8List input,
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    void Function(int processed, int total)? onProgress,
    void Function()? checkCancelled,
  }) async {
    if (input.isEmpty) throw const FormatException('attachment is empty');
    final noncePrefix = Uint8List.fromList(_randomBytes(8));
    final header = ByteData(attachmentEncryptionHeaderSize)
      ..buffer.asUint8List().setRange(0, 8, _attachmentMagic)
      ..setUint32(8, attachmentEncryptionChunkSize, Endian.big)
      ..setUint64(12, input.length, Endian.big)
      ..buffer.asUint8List().setRange(20, 28, noncePrefix);
    final output = BytesBuilder(copy: false)..add(header.buffer.asUint8List());
    var processed = 0;
    var index = 0;
    while (processed < input.length) {
      checkCancelled?.call();
      final end = min(processed + attachmentEncryptionChunkSize, input.length);
      final box = await _cipher.encrypt(
        input.sublist(processed, end),
        secretKey: channelKey,
        nonce: _attachmentNonce(noncePrefix, index),
        aad: _attachmentContext(channelId, epochId, input.length, index),
      );
      output.add(box.cipherText);
      output.add(box.mac.bytes);
      processed = end;
      index += 1;
      onProgress?.call(processed, input.length);
    }
    return AttachmentEncryptionBytesResult(
      bytes: output.takeBytes(),
      nonce: _encode(noncePrefix),
      plaintextSize: input.length,
    );
  }

  Future<File> decryptAttachmentFile({
    required File input,
    required File output,
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    required String nonce,
    required int plaintextSize,
    void Function(int processed, int total)? onProgress,
    void Function()? checkCancelled,
  }) async {
    final source = await input.open();
    await output.parent.create(recursive: true);
    final destination = await output.open(mode: FileMode.write);
    var processed = 0;
    try {
      final header = _parseAttachmentHeader(
        await source.read(attachmentEncryptionHeaderSize),
        nonce: nonce,
        plaintextSize: plaintextSize,
      );
      var index = 0;
      while (processed < header.plaintextSize) {
        checkCancelled?.call();
        final clearLength = min(
          header.chunkSize,
          header.plaintextSize - processed,
        );
        final encrypted = await source.read(clearLength + 16);
        if (encrypted.length != clearLength + 16) {
          throw const FormatException('attachment truncated');
        }
        final clear = await _decryptAttachmentChunk(
          encrypted,
          channelKey: channelKey,
          channelId: channelId,
          epochId: epochId,
          header: header,
          index: index,
        );
        await destination.writeFrom(clear);
        processed += clear.length;
        index += 1;
        onProgress?.call(processed, header.plaintextSize);
      }
      if (await source.position() != await input.length()) {
        throw const FormatException('invalid attachment length');
      }
    } catch (_) {
      await source.close();
      await destination.close();
      if (await output.exists()) await output.delete();
      rethrow;
    }
    await source.close();
    await destination.close();
    return output;
  }

  Future<Uint8List> decryptAttachmentBytes({
    required Uint8List input,
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    required String nonce,
    required int plaintextSize,
    void Function(int processed, int total)? onProgress,
    void Function()? checkCancelled,
  }) async {
    if (input.length < attachmentEncryptionHeaderSize) {
      throw const FormatException('attachment truncated');
    }
    final header = _parseAttachmentHeader(
      input.sublist(0, attachmentEncryptionHeaderSize),
      nonce: nonce,
      plaintextSize: plaintextSize,
    );
    final output = BytesBuilder(copy: false);
    var processed = 0;
    var offset = attachmentEncryptionHeaderSize;
    var index = 0;
    while (processed < header.plaintextSize) {
      checkCancelled?.call();
      final clearLength = min(
        header.chunkSize,
        header.plaintextSize - processed,
      );
      final encryptedEnd = offset + clearLength + 16;
      if (encryptedEnd > input.length) {
        throw const FormatException('attachment truncated');
      }
      output.add(
        await _decryptAttachmentChunk(
          input.sublist(offset, encryptedEnd),
          channelKey: channelKey,
          channelId: channelId,
          epochId: epochId,
          header: header,
          index: index,
        ),
      );
      offset = encryptedEnd;
      processed += clearLength;
      index += 1;
      onProgress?.call(processed, header.plaintextSize);
    }
    if (offset != input.length) {
      throw const FormatException('invalid attachment length');
    }
    return output.takeBytes();
  }

  Future<Uint8List> decryptAttachmentRange({
    required Future<Uint8List> Function(int start, int endInclusive)
    readCipherRange,
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    required String nonce,
    required int plaintextSize,
    required int start,
    required int endInclusive,
  }) async {
    if (start < 0 || endInclusive < start || start >= plaintextSize) {
      throw RangeError('invalid attachment range');
    }
    // ponytail: revalidate the 28-byte header per range; cache it only if
    // remote audio profiling shows the extra tiny request matters.
    final header = _parseAttachmentHeader(
      await readCipherRange(0, attachmentEncryptionHeaderSize - 1),
      nonce: nonce,
      plaintextSize: plaintextSize,
    );
    final end = min(endInclusive, plaintextSize - 1);
    final firstChunk = start ~/ header.chunkSize;
    final lastChunk = end ~/ header.chunkSize;
    final firstCipherOffset =
        attachmentEncryptionHeaderSize + firstChunk * (header.chunkSize + 16);
    final lastClearLength = min(
      header.chunkSize,
      header.plaintextSize - lastChunk * header.chunkSize,
    );
    final encryptedSpan = await readCipherRange(
      firstCipherOffset,
      attachmentEncryptionHeaderSize +
          lastChunk * (header.chunkSize + 16) +
          lastClearLength +
          15,
    );
    final clear = BytesBuilder(copy: false);
    var encryptedOffset = 0;
    for (var index = firstChunk; index <= lastChunk; index += 1) {
      final chunkClearStart = index * header.chunkSize;
      final chunkClearLength = min(
        header.chunkSize,
        header.plaintextSize - chunkClearStart,
      );
      final encryptedLength = chunkClearLength + 16;
      if (encryptedOffset + encryptedLength > encryptedSpan.length) {
        throw const FormatException('attachment chunk truncated');
      }
      final encrypted = encryptedSpan.sublist(
        encryptedOffset,
        encryptedOffset + encryptedLength,
      );
      encryptedOffset += encryptedLength;
      final chunk = await _decryptAttachmentChunk(
        encrypted,
        channelKey: channelKey,
        channelId: channelId,
        epochId: epochId,
        header: header,
        index: index,
      );
      final from = max(start, chunkClearStart) - chunkClearStart;
      final to = min(end + 1, chunkClearStart + chunk.length) - chunkClearStart;
      clear.add(chunk.sublist(from, to));
    }
    if (encryptedOffset != encryptedSpan.length) {
      throw const FormatException('attachment range length mismatch');
    }
    return clear.takeBytes();
  }

  Future<E2EEDeviceIdentity> _decode(String raw) async {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['version'] != 1 ||
        !RegExp(
          r'^dev_[0-9a-f]{32}$',
        ).hasMatch(value['device_id'] as String? ?? '')) {
      throw const FormatException('invalid stored device identity');
    }
    final identity = E2EEDeviceIdentity(
      deviceId: value['device_id'] as String,
      identitySeed: Uint8List.fromList(
        base64Url.decode(base64Url.normalize(value['identity_seed'] as String)),
      ),
      identityPublicKey: value['identity_public_key'] as String,
      envelopeSeed: Uint8List.fromList(
        base64Url.decode(base64Url.normalize(value['envelope_seed'] as String)),
      ),
      envelopePublicKey: value['envelope_public_key'] as String,
    );
    final identityPublic = await (await _identityAlgorithm.newKeyPairFromSeed(
      identity.identitySeed,
    )).extractPublicKey();
    final envelopePublic = await (await _envelopeAlgorithm.newKeyPairFromSeed(
      identity.envelopeSeed,
    )).extractPublicKey();
    if (!_sameBytes(
          identityPublic.bytes,
          _decodeBytes(identity.identityPublicKey),
        ) ||
        !_sameBytes(
          envelopePublic.bytes,
          _decodeBytes(identity.envelopePublicKey),
        )) {
      throw const FormatException('stored device key mismatch');
    }
    return identity;
  }

  String _encodeIdentity(E2EEDeviceIdentity identity) => jsonEncode({
    'version': 1,
    'device_id': identity.deviceId,
    'identity_seed': _encode(identity.identitySeed),
    'identity_public_key': identity.identityPublicKey,
    'envelope_seed': _encode(identity.envelopeSeed),
    'envelope_public_key': identity.envelopePublicKey,
  });

  String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  List<int> _decodeBytes(String value) =>
      base64Url.decode(base64Url.normalize(value));

  List<int> _envelopeContext(
    String channelId,
    String epochId,
    String senderDeviceId,
    String recipientDeviceId,
  ) => utf8.encode(
    jsonEncode([
      'OpenSpeak envelope v1',
      channelId,
      epochId,
      senderDeviceId,
      recipientDeviceId,
    ]),
  );

  List<int> _messageContext(String channelId, String epochId) => utf8.encode(
    jsonEncode(['OpenSpeak channel text v1', channelId, epochId]),
  );

  List<int> _attachmentContext(
    String channelId,
    String epochId,
    int plaintextSize,
    int chunkIndex,
  ) => utf8.encode(
    jsonEncode([
      'OpenSpeak attachment v1',
      channelId,
      epochId,
      plaintextSize,
      chunkIndex,
    ]),
  );

  Uint8List _attachmentNonce(Uint8List prefix, int index) {
    final nonce = Uint8List(12)..setRange(0, 8, prefix);
    ByteData.sublistView(nonce).setUint32(8, index, Endian.big);
    return nonce;
  }

  _AttachmentHeader _parseAttachmentHeader(
    List<int> bytes, {
    required String nonce,
    required int plaintextSize,
  }) {
    if (bytes.length != attachmentEncryptionHeaderSize ||
        !_sameBytes(bytes.sublist(0, 8), _attachmentMagic)) {
      throw const FormatException('invalid attachment header');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final header = _AttachmentHeader(
      chunkSize: data.getUint32(8, Endian.big),
      plaintextSize: data.getUint64(12, Endian.big),
      noncePrefix: Uint8List.fromList(bytes.sublist(20, 28)),
    );
    if (header.chunkSize != attachmentEncryptionChunkSize ||
        header.plaintextSize != plaintextSize ||
        !_sameBytes(header.noncePrefix, _decodeBytes(nonce))) {
      throw const FormatException('attachment metadata mismatch');
    }
    return header;
  }

  Future<List<int>> _decryptAttachmentChunk(
    List<int> encrypted, {
    required SecretKey channelKey,
    required String channelId,
    required String epochId,
    required _AttachmentHeader header,
    required int index,
  }) {
    return _cipher.decrypt(
      SecretBox(
        encrypted.sublist(0, encrypted.length - 16),
        nonce: _attachmentNonce(header.noncePrefix, index),
        mac: Mac(encrypted.sublist(encrypted.length - 16)),
      ),
      secretKey: channelKey,
      aad: _attachmentContext(channelId, epochId, header.plaintextSize, index),
    );
  }

  List<int> _signedEnvelope(List<int> context, List<Object> fields) => [
    ...context,
    0,
    ...utf8.encode(jsonEncode(fields)),
  ];

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<SecretKeyData> _checkedSharedSecret({
    required KeyPair keyPair,
    required PublicKey remotePublicKey,
  }) async {
    final bytes = await (await _envelopeAlgorithm.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    )).extractBytes();
    if (bytes.every((byte) => byte == 0)) {
      throw const FormatException('invalid X25519 public key');
    }
    return SecretKeyData(bytes);
  }

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index += 1) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  String _newDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'dev_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
  }
}

class _AttachmentHeader {
  _AttachmentHeader({
    required this.chunkSize,
    required this.plaintextSize,
    required this.noncePrefix,
  });

  final int chunkSize;
  final int plaintextSize;
  final Uint8List noncePrefix;
}
