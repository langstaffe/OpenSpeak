import 'dart:async';

import 'package:cryptography/cryptography.dart';

import 'device_identity_service.dart';
import 'openspeak_api.dart';

String mediaEncryptionScope(String channelId) => 'media:$channelId';

class ChannelKeyController {
  ChannelKeyController(this.deviceIdentity);

  final DeviceIdentityService deviceIdentity;
  final _keys = <String, SecretKeyData>{};
  final _loads = <String, Future<SecretKeyData>>{};
  final _envelopeArrivals = <String, Completer<void>>{};
  int _generation = 0;

  String _keyId(String channelId, String epochId, {bool media = false}) =>
      '$channelId:$epochId${media ? ':media' : ''}';

  void resetCoordination() {
    _generation += 1;
    _loads.clear();
    for (final arrival in _envelopeArrivals.values) {
      if (!arrival.isCompleted) arrival.complete();
    }
    _envelopeArrivals.clear();
  }

  void clear() => _keys.clear();

  void clearChannel(String channelId) =>
      _keys.removeWhere((key, _) => key.startsWith('$channelId:'));

  void handleEnvelopeCreated(
    String channelId,
    String epochId, {
    bool media = false,
  }) {
    final key = _keyId(channelId, epochId, media: media);
    final arrival = _envelopeArrivals.remove(key);
    if (arrival != null && !arrival.isCompleted) arrival.complete();
  }

  Future<SecretKeyData> ensureKey({
    required OpenSpeakApi api,
    required String token,
    required E2EEDeviceIdentity identity,
    required String channelId,
    String? epochId,
    bool media = false,
  }) async {
    if (epochId != null) {
      final cached = _keys[_keyId(channelId, epochId, media: media)];
      if (cached != null) return cached;
    }
    final loadId = _keyId(channelId, epochId ?? 'current', media: media);
    final pending = _loads[loadId];
    if (pending != null) return pending;
    final generation = _generation;
    final load = _loadKey(
      api: api,
      token: token,
      identity: identity,
      channelId: channelId,
      epochId: epochId,
      retry: 0,
      media: media,
      generation: generation,
    );
    _loads[loadId] = load;
    try {
      return await load;
    } finally {
      if (identical(_loads[loadId], load)) {
        _loads.remove(loadId);
      }
    }
  }

  Future<SecretKeyData> _loadKey({
    required OpenSpeakApi api,
    required String token,
    required E2EEDeviceIdentity identity,
    required String channelId,
    required String? epochId,
    required int retry,
    required bool media,
    required int generation,
  }) async {
    _ensureActive(generation);
    if (epochId != null) {
      final cached = _keys[_keyId(channelId, epochId, media: media)];
      if (cached != null) return cached;
    }
    final state = await api.getChannelE2EEState(token, channelId, media: media);
    _ensureActive(generation);
    final targetEpochId = epochId ?? state.epoch.id;
    final cached = _keys[_keyId(channelId, targetEpochId, media: media)];
    if (cached != null) return cached;
    final envelopes = await api.listKeyEnvelopes(
      token,
      channelId: channelId,
      recipientDeviceId: identity.deviceId,
      media: media,
    );
    _ensureActive(generation);
    final envelope = envelopes
        .where((item) => item.epochId == targetEpochId)
        .firstOrNull;
    if (envelope != null) {
      if (envelope.senderIdentityPublicKey.isEmpty) {
        throw OpenSpeakException('无法验证频道密钥发送设备');
      }
      final key = await deviceIdentity.unwrapChannelKey(
        recipient: identity,
        channelId: media ? mediaEncryptionScope(channelId) : channelId,
        epochId: targetEpochId,
        senderDeviceId: envelope.senderDeviceId,
        senderIdentityPublicKey: envelope.senderIdentityPublicKey,
        ciphertext: envelope.ciphertext,
      );
      _ensureActive(generation);
      _keys[_keyId(channelId, targetEpochId, media: media)] = key;
      if (targetEpochId == state.epoch.id) {
        await _distributeMissingKeys(
          api: api,
          token: token,
          identity: identity,
          channelId: channelId,
          state: state,
          channelKey: key,
          media: media,
        );
      }
      return key;
    }
    if (targetEpochId != state.epoch.id) {
      throw OpenSpeakException('当前设备没有此历史周期的频道密钥');
    }
    if (state.devices.isEmpty ||
        !state.devices.any((item) => item.id == identity.deviceId)) {
      throw OpenSpeakException('当前设备尚未注册端到端加密公钥');
    }
    if (state.devices.any((item) => item.hasEnvelope)) {
      final arrivalId = !media && retry == 0
          ? _keyId(channelId, targetEpochId)
          : null;
      final arrival = arrivalId == null
          ? null
          : _envelopeArrivals.putIfAbsent(arrivalId, Completer<void>.new);
      if (!media || retry == 0) {
        try {
          await api.requestChannelKey(
            token,
            channelId: channelId,
            epochId: state.epoch.id,
            recipientDeviceId: identity.deviceId,
            media: media,
          );
        } on OpenSpeakException catch (exception) {
          if (arrivalId != null &&
              identical(_envelopeArrivals[arrivalId], arrival)) {
            _envelopeArrivals.remove(arrivalId);
          }
          if (retry == 0 && exception.code == 'key_not_required') {
            return _loadKey(
              api: api,
              token: token,
              identity: identity,
              channelId: channelId,
              epochId: epochId,
              retry: 1,
              media: media,
              generation: generation,
            );
          }
          rethrow;
        } catch (_) {
          if (arrivalId != null &&
              identical(_envelopeArrivals[arrivalId], arrival)) {
            _envelopeArrivals.remove(arrivalId);
          }
          rethrow;
        }
      }
      if (media && retry < 10) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _loadKey(
          api: api,
          token: token,
          identity: identity,
          channelId: channelId,
          epochId: epochId,
          retry: retry + 1,
          media: true,
          generation: generation,
        );
      }
      if (arrivalId != null && arrival != null) {
        try {
          await arrival.future.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          // A reconnect may lose the WebSocket event. Recheck once.
        } finally {
          if (identical(_envelopeArrivals[arrivalId], arrival)) {
            _envelopeArrivals.remove(arrivalId);
          }
        }
        return _loadKey(
          api: api,
          token: token,
          identity: identity,
          channelId: channelId,
          epochId: targetEpochId,
          retry: 1,
          media: false,
          generation: generation,
        );
      }
      throw OpenSpeakException('正在等待其他在线设备分发频道密钥');
    }
    final key = await deviceIdentity.newChannelKey();
    _ensureActive(generation);
    try {
      await api.storeKeyEnvelopeBatch(
        token,
        channelId: channelId,
        epochId: state.epoch.id,
        senderDeviceId: identity.deviceId,
        envelopes: await _buildEnvelopes(
          state: state,
          identity: identity,
          channelKey: key,
          media: media,
        ),
        media: media,
      );
      _ensureActive(generation);
      _keys[_keyId(channelId, state.epoch.id, media: media)] = key;
      return key;
    } on OpenSpeakException catch (exception) {
      if (retry == 0 && exception.code == 'envelope_conflict') {
        return _loadKey(
          api: api,
          token: token,
          identity: identity,
          channelId: channelId,
          epochId: epochId,
          retry: 1,
          media: media,
          generation: generation,
        );
      }
      rethrow;
    }
  }

  void _ensureActive(int generation) {
    if (generation != _generation) {
      throw OpenSpeakException('频道密钥请求已取消');
    }
  }

  Future<List<KeyEnvelopeUpload>> _buildEnvelopes({
    required ChannelE2EEState state,
    required E2EEDeviceIdentity identity,
    required SecretKey channelKey,
    Iterable<ChannelE2EEDevice>? recipients,
    bool media = false,
  }) {
    final devices = recipients ?? state.devices;
    return Future.wait(
      devices.map(
        (recipient) async => KeyEnvelopeUpload(
          recipientUserId: recipient.userId,
          recipientDeviceId: recipient.id,
          ciphertext: await deviceIdentity.wrapChannelKey(
            sender: identity,
            channelId: media
                ? mediaEncryptionScope(state.epoch.channelId)
                : state.epoch.channelId,
            epochId: state.epoch.id,
            recipientDeviceId: recipient.id,
            recipientEnvelopePublicKey: recipient.envelopePublicKey,
            channelKey: channelKey,
          ),
        ),
      ),
    );
  }

  Future<void> _distributeMissingKeys({
    required OpenSpeakApi api,
    required String token,
    required E2EEDeviceIdentity identity,
    required String channelId,
    required ChannelE2EEState state,
    required SecretKey channelKey,
    bool media = false,
  }) async {
    final current = state.devices
        .where((item) => item.id == identity.deviceId)
        .firstOrNull;
    final missing = state.devices.where((item) => !item.hasEnvelope).toList();
    if (current?.hasEnvelope != true || missing.isEmpty) return;
    try {
      await api.storeKeyEnvelopeBatch(
        token,
        channelId: channelId,
        epochId: state.epoch.id,
        senderDeviceId: identity.deviceId,
        envelopes: await _buildEnvelopes(
          state: state,
          identity: identity,
          channelKey: channelKey,
          recipients: missing,
          media: media,
        ),
        media: media,
      );
    } on OpenSpeakException catch (exception) {
      if (exception.code != 'envelope_conflict') rethrow;
    }
  }

  Future<void> handleKeyRequest({
    required OpenSpeakApi api,
    required String token,
    required E2EEDeviceIdentity identity,
    required String channelId,
    bool media = false,
  }) async {
    final state = await api.getChannelE2EEState(token, channelId, media: media);
    final current = state.devices
        .where((item) => item.id == identity.deviceId)
        .firstOrNull;
    if (current?.hasEnvelope != true) return;
    final cached = _keys[_keyId(channelId, state.epoch.id, media: media)];
    if (cached != null) {
      await _distributeMissingKeys(
        api: api,
        token: token,
        identity: identity,
        channelId: channelId,
        state: state,
        channelKey: cached,
        media: media,
      );
    } else {
      await ensureKey(
        api: api,
        token: token,
        identity: identity,
        channelId: channelId,
        epochId: state.epoch.id,
        media: media,
      );
    }
  }
}
