import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef TransferProgress = void Function(int transferredBytes, int totalBytes);

const legacyLocalAttachmentFileMaxBytes = 512 * 1024 * 1024;
const localAttachmentImageMaxBytes = 128 * 1024 * 1024;

int legacyLocalAttachmentMaxBytes(String kind) => kind == 'image'
    ? localAttachmentImageMaxBytes
    : legacyLocalAttachmentFileMaxBytes;

bool externalAttachmentCanFallback(
  Object error, {
  required int sizeBytes,
  required int localMaxBytes,
}) =>
    sizeBytes <= localMaxBytes &&
    (error is SocketException ||
        error is HandshakeException ||
        error is HttpException ||
        (error is OpenSpeakException &&
            (error.statusCode == HttpStatus.requestTimeout ||
                error.statusCode == HttpStatus.tooManyRequests ||
                error.statusCode >= 500)));

bool apiConnectShouldRetry(Object error, int attempt) =>
    error is SocketException && attempt == 0;

Uri? legacyPlainDiscoveryBase(Uri currentBase) {
  if (currentBase.scheme != 'https' ||
      (currentBase.port != 443 && currentBase.port != 27410)) {
    return null;
  }
  return currentBase.replace(scheme: 'http', port: 27410);
}

Uri? canonicalServerBaseUri(Uri currentBase, Object? response) {
  if (response is! Map) return null;
  final requiredScheme = switch (response['error']) {
    'https_required' => 'https',
    'http_required' => 'http',
    _ => '',
  };
  if (requiredScheme.isEmpty) return null;
  if (requiredScheme == 'http' && currentBase.scheme != 'https') return null;
  final rawUrl =
      response[requiredScheme == 'https' ? 'secure_url' : 'plain_url'];
  if (rawUrl is! String) return null;
  final trimmed = rawUrl.trim();
  final base = Uri.tryParse(
    trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed,
  );
  if (base == null || base.scheme != requiredScheme || base.host.isEmpty) {
    return null;
  }
  return base == currentBase ? null : base;
}

class TransferCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled(String message) {
    if (_cancelled) {
      throw OpenSpeakException(message);
    }
  }
}

class OpenSpeakApi {
  OpenSpeakApi(String baseUrl)
    : baseUri = Uri.parse(
        baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
      ) {
    _latencyClient.idleTimeout = const Duration(seconds: 10);
  }

  Uri baseUri;
  final HttpClient _latencyClient = HttpClient();
  bool _latencyConnectionWarmed = false;

  Uri apiUri(String path, [Map<String, String>? query]) {
    return baseUri.replace(
      path: '${baseUri.path}$path',
      queryParameters: query,
    );
  }

  Future<double> measureLatencyMs() async {
    if (!_latencyConnectionWarmed) {
      await _healthProbe();
      _latencyConnectionWarmed = true;
    }
    final stopwatch = Stopwatch()..start();
    await _healthProbe();
    stopwatch.stop();
    return stopwatch.elapsedMicroseconds / 1000;
  }

  Future<void> _healthProbe() async {
    final request = await _latencyClient.getUrl(apiUri('/api/health'));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OpenSpeakException('HTTP ${response.statusCode}: health probe');
    }
  }

  Future<AuthSession> login(
    String displayName,
    String serverPassword, {
    String clientInstallationId = '',
  }) async {
    final json = await request(
      'POST',
      '/api/v1/auth/login',
      retryCanonicalAddress: false,
      body: {
        'display_name': displayName,
        'password': serverPassword,
        'client_installation_id': clientInstallationId,
      },
    );
    return AuthSession.fromJson(json);
  }

  Future<String> discoverSecureUrl() async {
    dynamic json;
    try {
      json = await request('GET', '/api/health');
    } catch (_) {
      final fallback = legacyPlainDiscoveryBase(baseUri);
      if (fallback == null) rethrow;
      final fallbackApi = OpenSpeakApi(fallback.toString());
      json = await fallbackApi.request('GET', '/api/health');
      baseUri = fallbackApi.baseUri;
    }
    return json['secure_url'] as String? ??
        json['plain_url'] as String? ??
        baseUri.toString();
  }

  Future<User> updateCurrentUserDisplayName(
    String token,
    String displayName,
  ) async {
    final json = await request(
      'PATCH',
      '/api/v1/users/me',
      token: token,
      body: {'display_name': displayName},
    );
    return User.fromJson(json);
  }

  Uri userAvatarUri(String userId, int version, {bool small = false}) => apiUri(
    '/api/v1/users/$userId/avatar',
    {'v': '$version', if (small) 'size': 'small', if (small) 'thumb': 'png-v1'},
  );

  Uri serverAvatarUri(String serverId, int version, {bool small = false}) =>
      apiUri('/api/v1/servers/$serverId/avatar', {
        'v': '$version',
        if (small) 'size': 'small',
      });

  Future<User> uploadCurrentUserAvatar(String token, File file) async {
    final json = await _uploadAvatar(token, '/api/v1/users/me/avatar', file);
    return User.fromJson(json);
  }

  Future<OsServer> updateServerProfile(
    String token,
    String serverId,
    String name,
  ) async {
    final json = await request(
      'PATCH',
      '/api/v1/servers/$serverId/settings',
      token: token,
      body: {'name': name},
    );
    return OsServer.fromJson(json);
  }

  Future<OsServer> getServerSettings(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/settings',
      token: token,
    );
    return OsServer.fromJson(json);
  }

  Future<OsServer> updateServerGeneralSettings(
    String token,
    String serverId, {
    required int historyRetentionDays,
    required String defaultChannelId,
    String? serverPassword,
    bool clearServerPassword = false,
  }) async {
    final json = await request(
      'PATCH',
      '/api/v1/servers/$serverId/settings',
      token: token,
      body: {
        'history_retention_days': historyRetentionDays,
        'default_channel_id': defaultChannelId,
        'server_password': ?serverPassword,
        if (clearServerPassword) 'clear_server_password': true,
      },
    );
    return OsServer.fromJson(json);
  }

  Future<OsServer> uploadServerAvatar(
    String token,
    String serverId,
    File file,
  ) async {
    final json = await _uploadAvatar(
      token,
      '/api/v1/servers/$serverId/avatar',
      file,
    );
    return OsServer.fromJson(json);
  }

  Future<Map<String, dynamic>> _uploadAvatar(
    String token,
    String path,
    File file,
  ) async {
    final client = HttpClient();
    final boundary =
        'openspeak-avatar-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final request = await client.openUrl('PUT', apiUri(path));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      final fileName = file.uri.pathSegments.isEmpty
          ? 'avatar'
          : file.uri.pathSegments.last;
      final header =
          '--$boundary\r\nContent-Disposition: form-data; name="avatar"; filename="${multipartFallbackFileName(fileName)}"\r\nContent-Type: ${contentTypeForPath(file.path)}\r\n\r\n';
      final footer = '\r\n--$boundary--\r\n';
      request.contentLength =
          utf8.encode(header).length +
          await file.length() +
          utf8.encode(footer).length;
      request.add(utf8.encode(header));
      await request.addStream(file.openRead());
      request.add(utf8.encode(footer));
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final decoded = responseBody.isEmpty ? null : jsonDecode(responseBody);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw apiException(response.statusCode, decoded, responseBody);
      }
      return (decoded as Map).cast<String, dynamic>();
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> downloadUserAvatar(
    String token,
    String userId,
    int version,
  ) => _downloadAvatar(userAvatarUri(userId, version), token: token);

  Future<Uint8List> downloadServerAvatar(String serverId, int version) =>
      _downloadAvatar(serverAvatarUri(serverId, version));

  Future<Uint8List> _downloadAvatar(Uri uri, {String token = ''}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      if (token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();
      final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(),
        (builder, chunk) => builder..add(chunk),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OpenSpeakException('HTTP ${response.statusCode}: 无法下载头像');
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<Device> registerDevice(
    String token,
    String userId,
    String label, {
    String deviceId = '',
    String identityPublicKey = '',
    String envelopePublicKey = '',
  }) async {
    final json = await request(
      'POST',
      '/api/v1/users/$userId/devices',
      token: token,
      body: {
        'device_id': deviceId,
        'label': label,
        'identity_public_key': identityPublicKey,
        'envelope_public_key': envelopePublicKey,
      },
    );
    return Device.fromJson(json);
  }

  Future<List<OsServer>> listServers(String token) async {
    final json = await request('GET', '/api/v1/servers', token: token);
    return listFromJson(json, OsServer.fromJson);
  }

  Future<OwnerStatus> getOwnerStatus(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/owner/status',
      token: token,
    );
    return OwnerStatus.fromJson(json);
  }

  Future<List<ManagedServerMember>> listManagedServerMembers(
    String token,
    String serverId,
  ) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/members/manage',
      token: token,
    );
    return listFromJson(json, ManagedServerMember.fromJson);
  }

  Future<void> updateServerMemberRole(
    String token,
    String serverId,
    String userId,
    String role,
  ) async {
    await request(
      'PUT',
      '/api/v1/servers/$serverId/members/$userId',
      token: token,
      body: {'role': role, 'permissions': <String>[]},
    );
  }

  Future<void> kickServerMember(
    String token,
    String serverId,
    String userId,
  ) async {
    await request(
      'POST',
      '/api/v1/servers/$serverId/members/$userId/kick',
      token: token,
    );
  }

  Future<void> banServerMember(
    String token,
    String serverId,
    String userId, {
    required String reason,
    required int durationSeconds,
  }) async {
    await request(
      'POST',
      '/api/v1/servers/$serverId/members/$userId/ban',
      token: token,
      body: {'reason': reason, 'duration_seconds': durationSeconds},
    );
  }

  Future<void> unbanServerMember(
    String token,
    String serverId,
    String userId,
  ) async {
    await request(
      'DELETE',
      '/api/v1/servers/$serverId/members/$userId/ban',
      token: token,
    );
  }

  Future<void> forceMuteServerMember(
    String token,
    String serverId,
    String userId,
  ) async {
    await request(
      'POST',
      '/api/v1/servers/$serverId/members/$userId/mute',
      token: token,
    );
  }

  Future<void> forceDeafenServerMember(
    String token,
    String serverId,
    String userId,
  ) async {
    await request(
      'POST',
      '/api/v1/servers/$serverId/members/$userId/deafen',
      token: token,
    );
  }

  Future<ServerPermissionSettings> getServerPermissions(
    String token,
    String serverId,
  ) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/permissions',
      token: token,
    );
    return ServerPermissionSettings.fromJson(json);
  }

  Future<ServerPermissionSettings> updateServerPermissions(
    String token,
    String serverId, {
    required Set<String> admin,
    required Set<String> user,
    required int messageRetractWindowMinutes,
  }) async {
    final json = await request(
      'PUT',
      '/api/v1/servers/$serverId/permissions',
      token: token,
      body: {
        'admin': admin.toList(),
        'user': user.toList(),
        'message_retract_window_minutes': messageRetractWindowMinutes,
      },
    );
    return ServerPermissionSettings.fromJson(json);
  }

  Future<List<AuditLogEntry>> listAuditLogs(
    String token,
    String serverId,
  ) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/audit-logs',
      token: token,
    );
    return listFromJson(json, AuditLogEntry.fromJson);
  }

  Future<OwnerChallenge> createOwnerChallenge(
    String token,
    String serverId, {
    required String method,
    String? deviceId,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/owner/challenges',
      token: token,
      body: {'method': method, 'device_id': ?deviceId},
    );
    return OwnerChallenge.fromJson(json);
  }

  Future<OwnerAuthResult> authenticateOwner(
    String token,
    String serverId, {
    required String challengeId,
    required String signature,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/owner/authenticate',
      token: token,
      body: {'challenge_id': challengeId, 'signature': signature},
    );
    return OwnerAuthResult.fromJson(json);
  }

  Future<OwnerAuthResult> claimOwner(
    String token,
    String serverId, {
    required String claimKey,
    required OwnerDeviceRegistration device,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/owner/claim',
      token: token,
      body: {'claim_key': claimKey, 'device': device.toJson()},
    );
    return OwnerAuthResult.fromJson(json);
  }

  Future<OwnerAuthResult> pairOwnerDevice(
    String token,
    String serverId, {
    required String code,
    required OwnerDeviceRegistration device,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/owner/pair',
      token: token,
      body: {'code': code, 'device': device.toJson()},
    );
    return OwnerAuthResult.fromJson(json);
  }

  Future<OwnerPairingCode> createOwnerPairingCode(
    String token,
    String serverId, {
    required String challengeId,
    required String signature,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/owner/pairing-codes',
      token: token,
      body: {'challenge_id': challengeId, 'signature': signature},
    );
    return OwnerPairingCode.fromJson(json);
  }

  Future<List<OwnerDeviceInfo>> listOwnerDevices(
    String token,
    String serverId,
  ) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/owner/devices',
      token: token,
    );
    return listFromJson(json, OwnerDeviceInfo.fromJson);
  }

  Future<void> kickOwnerDevice(
    String token,
    String serverId,
    String deviceId, {
    required String challengeId,
    required String signature,
  }) async {
    await request(
      'POST',
      '/api/v1/servers/$serverId/owner/devices/$deviceId/kick',
      token: token,
      body: {'challenge_id': challengeId, 'signature': signature},
    );
  }

  Future<void> revokeOwnerDevice(
    String token,
    String serverId,
    String deviceId, {
    required String challengeId,
    required String signature,
  }) async {
    await request(
      'DELETE',
      '/api/v1/servers/$serverId/owner/devices/$deviceId',
      token: token,
      body: {'challenge_id': challengeId, 'signature': signature},
    );
  }

  Future<OsServer> setServerEncryptionMode(
    String token,
    String serverId,
    String encryptionMode,
  ) async {
    final json = await request(
      'PATCH',
      '/api/v1/servers/$serverId/settings',
      token: token,
      body: {'encryption_mode': encryptionMode},
    );
    return OsServer.fromJson(json);
  }

  Future<OsServer> updateServerVoiceTransport(
    String token,
    String serverId, {
    required String encryptionMode,
    required int voiceAudioBitrateKbps,
    required ScreenShareBitrateLimits screenShareBitrateLimits,
  }) async {
    final body = <String, dynamic>{
      'encryption_mode': encryptionMode,
      'voice_audio_bitrate_kbps': voiceAudioBitrateKbps,
      'screen_share_bitrate_limits_mbps': screenShareBitrateLimits.toJson(),
    };
    Map<String, dynamic> json;
    try {
      json = await request(
        'PATCH',
        '/api/v1/servers/$serverId/settings',
        token: token,
        body: body,
      );
    } on OpenSpeakException catch (error) {
      if (error.statusCode != 400 ||
          !error.message.contains(
            'unknown field "screen_share_bitrate_limits_mbps"',
          )) {
        rethrow;
      }
      body.remove('screen_share_bitrate_limits_mbps');
      json = await request(
        'PATCH',
        '/api/v1/servers/$serverId/settings',
        token: token,
        body: body,
      );
    }
    return OsServer.fromJson(json);
  }

  Future<TlsApplyResult> enableServerTls(
    String token,
    String serverId, {
    required String certificateType,
    required String identifier,
    required String challengeId,
    required String signature,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/tls',
      token: token,
      body: {
        'certificate_type': certificateType,
        'identifier': identifier,
        'challenge_id': challengeId,
        'signature': signature,
      },
    );
    return TlsApplyResult.fromJson(json);
  }

  Future<String> detectServerPublicIp(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/tls/public-ip',
      token: token,
    );
    return json['public_ip'] as String? ?? '';
  }

  Future<OsServer> confirmServerTls(
    String token,
    String serverId, {
    required String confirmationToken,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/tls/confirm',
      token: token,
      body: {'confirmation_token': confirmationToken},
    );
    return OsServer.fromJson(json);
  }

  Future<EncryptionDowngradeResult> beginEncryptionDowngrade(
    String token,
    String serverId, {
    required String challengeId,
    required String signature,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/encryption/downgrade',
      token: token,
      body: {'challenge_id': challengeId, 'signature': signature},
    );
    return EncryptionDowngradeResult.fromJson(json);
  }

  Future<OsServer> confirmEncryptionDowngrade(String confirmationToken) async {
    final json = await request(
      'POST',
      '/api/v1/encryption/downgrade/confirm',
      body: {'confirmation_token': confirmationToken},
    );
    return OsServer.fromJson(json);
  }

  Future<List<FileNode>> listFileNodes(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/file-nodes',
      token: token,
    );
    return listFromJson(json, FileNode.fromJson);
  }

  Future<FileNode> createFileNode(
    String token,
    String serverId, {
    required String name,
    required String baseUrl,
    required String secret,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/file-nodes',
      token: token,
      body: {'name': name, 'base_url': baseUrl, 'secret': secret},
    );
    return FileNode.fromJson(json);
  }

  Future<FileNode> updateFileNode(
    String token,
    String serverId,
    String nodeId, {
    required String baseUrl,
    String? secret,
    bool? enabled,
  }) async {
    final json = await request(
      'PATCH',
      '/api/v1/servers/$serverId/file-nodes/$nodeId',
      token: token,
      body: {'base_url': baseUrl, 'secret': ?secret, 'enabled': ?enabled},
    );
    return FileNode.fromJson(json);
  }

  Future<OsServer> setExternalAttachments(
    String token,
    String serverId, {
    required bool enabled,
    String? fileNodeId,
  }) async {
    final json = await request(
      'PATCH',
      '/api/v1/servers/$serverId/settings',
      token: token,
      body: {
        'attachment_external_enabled': enabled,
        'attachment_file_node_id': ?fileNodeId,
      },
    );
    return OsServer.fromJson(json);
  }

  Future<List<MediaNode>> listMediaNodes(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/media-nodes',
      token: token,
    );
    return listFromJson(json, MediaNode.fromJson);
  }

  Future<MediaNode> updateMediaNodeLiveKitUrl(
    String token,
    String serverId,
    String nodeId,
    String liveKitUrl,
  ) async {
    final json = await request(
      'PATCH',
      '/api/v1/servers/$serverId/media-nodes/$nodeId',
      token: token,
      body: {'livekit_url': liveKitUrl},
    );
    return MediaNode.fromJson(json);
  }

  Future<MediaNode> createMediaNode(
    String token,
    String serverId, {
    required String name,
    required String liveKitUrl,
    required String apiKey,
    required String apiSecret,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/media-nodes',
      token: token,
      body: {
        'name': name,
        'livekit_url': liveKitUrl,
        'api_key': apiKey,
        'api_secret': apiSecret,
        'enabled': true,
      },
    );
    return MediaNode.fromJson(json);
  }

  Future<MediaNode> updateMediaNode(
    String token,
    String serverId,
    String nodeId, {
    String? name,
    String? liveKitUrl,
    String? apiKey,
    String? apiSecret,
    bool? enabled,
    bool? draining,
  }) async {
    final json = await request(
      'PATCH',
      '/api/v1/servers/$serverId/media-nodes/$nodeId',
      token: token,
      body: {
        'name': ?name,
        'livekit_url': ?liveKitUrl,
        'api_key': ?apiKey,
        'api_secret': ?apiSecret,
        'enabled': ?enabled,
        'draining': ?draining,
      },
    );
    return MediaNode.fromJson(json);
  }

  Future<List<Channel>> listChannels(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/channels',
      token: token,
    );
    return listFromJson(json, Channel.fromJson);
  }

  Future<Channel> createChannel(
    String token,
    String serverId,
    String name, {
    required int sortOrder,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/servers/$serverId/channels',
      token: token,
      body: {'name': name, 'sort_order': sortOrder},
    );
    return Channel.fromJson(json);
  }

  Future<Channel> updateChannelName(
    String token,
    String channelId,
    String name,
  ) async {
    final json = await request(
      'PATCH',
      '/api/v1/channels/$channelId',
      token: token,
      body: {'name': name},
    );
    return Channel.fromJson(json);
  }

  Future<Channel> updateChannelSortOrder(
    String token,
    String channelId,
    int sortOrder,
  ) async {
    final json = await request(
      'PATCH',
      '/api/v1/channels/$channelId',
      token: token,
      body: {'sort_order': sortOrder},
    );
    return Channel.fromJson(json);
  }

  Future<void> deleteChannel(String token, String channelId) async {
    await request('DELETE', '/api/v1/channels/$channelId', token: token);
  }

  Future<List<ChannelMember>> listChannelMembers(
    String token,
    String channelId,
  ) async {
    final json = await request(
      'GET',
      '/api/v1/channels/$channelId/members',
      token: token,
    );
    return listFromJson(json, ChannelMember.fromJson);
  }

  Future<void> joinChannel(
    String token,
    String channelId, {
    required String userId,
  }) async {
    await request(
      'POST',
      '/api/v1/channels/$channelId/join',
      token: token,
      body: {'user_id': userId, 'role': 'member'},
    );
  }

  Future<void> accessChannel(String token, String channelId) async {
    await request(
      'POST',
      '/api/v1/channels/$channelId/join',
      token: token,
      body: {'access_only': true},
    );
  }

  Future<void> leaveChannel(
    String token,
    String channelId, {
    required String userId,
  }) async {
    await request(
      'POST',
      '/api/v1/channels/$channelId/leave',
      token: token,
      body: {'user_id': userId},
    );
  }

  Future<PresenceSnapshot> getPresence(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/presence',
      token: token,
    );
    return PresenceSnapshot.fromJson(json);
  }

  Future<ServerState> getServerState(String token, String serverId) async {
    final json = await request(
      'GET',
      '/api/v1/servers/$serverId/state',
      token: token,
    );
    return ServerState.fromJson(json);
  }

  Future<VoiceState> setVoiceState(
    String token,
    String serverId,
    String channelId, {
    required bool muted,
    required bool deafened,
    required bool speaking,
    bool screenSharing = false,
    String screenShareResolution = '',
    int screenShareFPS = 0,
    String screenShareMediaNodeId = '',
  }) async {
    final json = await request(
      'PUT',
      '/api/v1/servers/$serverId/voice-state',
      token: token,
      body: {
        'channel_id': channelId,
        'muted': muted,
        'deafened': deafened,
        'speaking': speaking,
        'screen_sharing': screenSharing,
        if (screenSharing) 'screen_share_resolution': screenShareResolution,
        if (screenSharing) 'screen_share_fps': screenShareFPS,
        if (screenSharing) 'screen_share_media_node_id': screenShareMediaNodeId,
      },
    );
    return VoiceState.fromJson(json);
  }

  Future<void> clearVoiceState(String token, String serverId) async {
    await request(
      'DELETE',
      '/api/v1/servers/$serverId/voice-state',
      token: token,
    );
  }

  Future<VoiceToken> getVoiceToken(
    String token,
    String channelId, {
    String deviceId = '',
    String e2eeEpochId = '',
    bool persistentRoom = true,
    bool e2eeParticipantKeys = true,
  }) async {
    final body = {
      if (persistentRoom) 'persistent_room': true,
      if (persistentRoom && e2eeParticipantKeys) 'e2ee_participant_keys': true,
      'media_key_slots': true,
      if (deviceId.isNotEmpty) 'device_id': deviceId,
      if (e2eeEpochId.isNotEmpty) 'e2ee_epoch_id': e2eeEpochId,
    };
    while (true) {
      try {
        final json = await request(
          'POST',
          '/api/v1/channels/$channelId/voice-token',
          token: token,
          body: body,
        );
        return VoiceToken.fromJson(json);
      } on OpenSpeakException catch (error) {
        if (error.statusCode != 400) rethrow;
        final unsupportedField = switch (error.message) {
          final message
              when message.contains('unknown field "persistent_room"') =>
            'persistent_room',
          final message
              when message.contains('unknown field "e2ee_participant_keys"') =>
            'e2ee_participant_keys',
          final message
              when message.contains('unknown field "media_key_slots"') =>
            'media_key_slots',
          _ => '',
        };
        if (unsupportedField.isEmpty || !body.containsKey(unsupportedField)) {
          rethrow;
        }
        body.remove(unsupportedField);
      }
    }
  }

  Future<ScreenShareToken> getScreenShareToken(
    String token,
    String channelId, {
    required bool publish,
    String publisherUserId = '',
    String resolution = '',
    int fps = 0,
    String deviceId = '',
    String e2eeEpochId = '',
  }) async {
    final json = await request(
      'POST',
      '/api/v1/channels/$channelId/screen-share-token',
      token: token,
      body: {
        'publish': publish,
        if (publisherUserId.isNotEmpty) 'publisher_user_id': publisherUserId,
        if (resolution.isNotEmpty) 'resolution': resolution,
        if (fps > 0) 'fps': fps,
        if (deviceId.isNotEmpty) 'device_id': deviceId,
        if (e2eeEpochId.isNotEmpty) 'e2ee_epoch_id': e2eeEpochId,
      },
    );
    return ScreenShareToken.fromJson(json);
  }

  Future<List<ChannelMessage>> listChannelMessages(
    String token,
    String channelId, {
    int limit = 50,
  }) async {
    final json = await request(
      'GET',
      '/api/v1/channels/$channelId/messages',
      token: token,
      query: {'limit': '$limit'},
    );
    return listFromJson(json, ChannelMessage.fromJson);
  }

  Future<ChannelE2EEState> getChannelE2EEState(
    String token,
    String channelId, {
    bool media = false,
  }) async {
    final json = await request(
      'GET',
      '/api/v1/channels/$channelId/${media ? 'media-e2ee' : 'e2ee'}',
      token: token,
    );
    return ChannelE2EEState.fromJson(json as Map<String, dynamic>);
  }

  Future<MediaKeyReady> markMediaKeyReady(
    String token, {
    required String channelId,
    required String epochId,
    required String deviceId,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/e2ee/media-key-ready',
      token: token,
      body: {
        'channel_id': channelId,
        'epoch_id': epochId,
        'device_id': deviceId,
      },
    );
    return MediaKeyReady.fromJson((json as Map).cast<String, dynamic>());
  }

  Future<List<ChannelE2EEDevice>> getDirectE2EEDevices(
    String token, {
    required String serverId,
    required String toUserId,
  }) async {
    final json = await request(
      'GET',
      '/api/v1/e2ee/direct-devices',
      token: token,
      query: {'server_id': serverId, 'to_user_id': toUserId},
    );
    return listFromJson(json, ChannelE2EEDevice.fromJson);
  }

  Future<List<KeyEnvelope>> listKeyEnvelopes(
    String token, {
    required String channelId,
    required String recipientDeviceId,
    bool media = false,
  }) async {
    final json = await request(
      'GET',
      '/api/v1/e2ee/${media ? 'media-envelopes' : 'envelopes'}',
      token: token,
      query: {
        'channel_id': channelId,
        'recipient_device_id': recipientDeviceId,
      },
    );
    return listFromJson(json, KeyEnvelope.fromJson);
  }

  Future<List<KeyEnvelope>> storeKeyEnvelopeBatch(
    String token, {
    required String channelId,
    required String epochId,
    required String senderDeviceId,
    required List<KeyEnvelopeUpload> envelopes,
    bool media = false,
  }) async {
    final json = await request(
      'POST',
      '/api/v1/e2ee/${media ? 'media-envelopes' : 'envelopes'}',
      token: token,
      body: {
        'channel_id': channelId,
        'epoch_id': epochId,
        'sender_device_id': senderDeviceId,
        'envelopes': envelopes.map((envelope) => envelope.toJson()).toList(),
      },
    );
    return listFromJson(json, KeyEnvelope.fromJson);
  }

  Future<void> requestChannelKey(
    String token, {
    required String channelId,
    required String epochId,
    required String recipientDeviceId,
    bool media = false,
  }) async {
    await request(
      'POST',
      '/api/v1/e2ee/${media ? 'media-key-requests' : 'key-requests'}',
      token: token,
      body: {
        'channel_id': channelId,
        'epoch_id': epochId,
        'recipient_device_id': recipientDeviceId,
      },
    );
  }

  Future<void> deleteChannelMessage(
    String token,
    String channelId,
    String messageId, {
    required bool moderatorDelete,
  }) async {
    await request(
      'DELETE',
      '/api/v1/channels/$channelId/messages/$messageId',
      token: token,
      query: {'action': moderatorDelete ? 'delete' : 'retract'},
    );
  }

  Future<ChannelMessage> sendChannelTextMessage(
    String token,
    String channelId,
    String body,
    String encryptionMode, {
    String epochId = '',
    String nonce = '',
  }) async {
    final json = await request(
      'POST',
      '/api/v1/channels/$channelId/messages',
      token: token,
      body: {
        'kind': 'text',
        'body': body,
        'encryption_mode': encryptionMode,
        'epoch_id': epochId,
        'nonce': nonce,
      },
    );
    return ChannelMessage.fromJson(json as Map<String, dynamic>);
  }

  Future<LinkPreview> getLinkPreview(String token, String url) async {
    final json = await request(
      'GET',
      '/api/v1/link-preview',
      token: token,
      query: {'url': url},
    );
    return LinkPreview.fromJson((json as Map).cast<String, dynamic>());
  }

  Future<ChannelUploadResult> uploadChannelImage(
    String token,
    String channelId,
    File file, {
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
  }) {
    return uploadChannelAttachment(
      token,
      channelId,
      file,
      endpoint: 'images',
      fieldName: 'image',
      encryptionMode: encryptionMode,
      originalName: originalName,
      contentType: contentType,
      epochId: epochId,
      nonce: nonce,
      plaintextSizeBytes: plaintextSizeBytes,
      attachmentFormat: attachmentFormat,
      chunkSize: chunkSize,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<ChannelUploadResult> uploadChannelFile(
    String token,
    String channelId,
    File file, {
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
  }) {
    return uploadChannelAttachment(
      token,
      channelId,
      file,
      endpoint: 'files',
      fieldName: 'file',
      encryptionMode: encryptionMode,
      originalName: originalName,
      contentType: contentType,
      epochId: epochId,
      nonce: nonce,
      plaintextSizeBytes: plaintextSizeBytes,
      attachmentFormat: attachmentFormat,
      chunkSize: chunkSize,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<ChannelUploadResult> uploadChannelAttachment(
    String token,
    String channelId,
    File file, {
    required String endpoint,
    required String fieldName,
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
    final fileName =
        originalName ??
        (file.uri.pathSegments.isEmpty ? 'upload' : file.uri.pathSegments.last);
    final uploadContentType = contentType ?? contentTypeForPath(file.path);
    final kind = endpoint == 'images' ? 'image' : 'file';
    final fileLength = await file.length();
    final fallbackSize = encryptionMode == 'e2ee'
        ? plaintextSizeBytes
        : fileLength;
    AttachmentUploadPlan? plan;
    try {
      plan = await initiateAttachmentUpload(
        token,
        channelId: channelId,
        kind: kind,
        file: file,
        originalName: fileName,
        contentType: uploadContentType,
        encryptionMode: encryptionMode,
        epochId: epochId,
        nonce: nonce,
        plaintextSizeBytes: plaintextSizeBytes,
        attachmentFormat: attachmentFormat,
        chunkSize: chunkSize,
      );
    } on OpenSpeakException catch (error) {
      if (cancelToken?.isCancelled == true) rethrow;
      if (error.statusCode != HttpStatus.notFound ||
          fallbackSize > legacyLocalAttachmentMaxBytes(kind)) {
        rethrow;
      }
    }
    if (plan?.external == true) {
      final externalPlan = plan!;
      var uploaded = false;
      try {
        await uploadExternalAttachment(
          externalPlan,
          file,
          onProgress: onProgress,
          cancelToken: cancelToken,
          contentType: uploadContentType,
        );
        uploaded = true;
      } catch (error) {
        if (cancelToken?.isCancelled == true ||
            !externalAttachmentCanFallback(
              error,
              sizeBytes: fallbackSize,
              localMaxBytes: externalPlan.localMaxBytes,
            )) {
          rethrow;
        }
        onProgress?.call(0, fileLength);
      }
      if (uploaded) {
        final completed = await request(
          'POST',
          '/api/v1/attachment-uploads/complete',
          token: token,
          body: {'completion_token': externalPlan.completionToken},
        );
        return ChannelUploadResult.fromJson(
          (completed as Map).cast<String, dynamic>(),
        );
      }
    }
    final client = HttpClient();
    final boundary = 'openspeak-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final request = await client.openUrl(
        'POST',
        apiUri('/api/v1/channels/$channelId/$endpoint'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      final originalNameField =
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="original_name"\r\n\r\n'
          '$fileName\r\n';
      final encryptionModeField =
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="encryption_mode"\r\n\r\n'
          '$encryptionMode\r\n';
      final encryptionFields =
          '--$boundary\r\nContent-Disposition: form-data; name="epoch_id"\r\n\r\n$epochId\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="nonce"\r\n\r\n$nonce\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="plaintext_size_bytes"\r\n\r\n$plaintextSizeBytes\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="attachment_format"\r\n\r\n$attachmentFormat\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="chunk_size"\r\n\r\n$chunkSize\r\n';
      final fileHeader =
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="$fieldName"; filename="${multipartFallbackFileName(fileName)}"\r\n'
          'Content-Type: $uploadContentType\r\n\r\n';
      const multipartFooterPrefix = '\r\n';
      final multipartFooter = '$multipartFooterPrefix--$boundary--\r\n';
      request.contentLength =
          utf8.encode(originalNameField).length +
          utf8.encode(encryptionModeField).length +
          utf8.encode(encryptionFields).length +
          utf8.encode(fileHeader).length +
          fileLength +
          utf8.encode(multipartFooter).length;
      void writeAscii(String value) => request.add(utf8.encode(value));

      writeAscii(originalNameField);
      writeAscii(encryptionModeField);
      writeAscii(encryptionFields);
      writeAscii(fileHeader);
      await addFileWithProgress(
        request,
        file,
        onProgress: onProgress,
        cancelToken: cancelToken,
        cancelMessage: '上传已取消',
      );
      writeAscii(multipartFooter);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final decoded = responseBody.isEmpty ? null : jsonDecode(responseBody);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw apiException(response.statusCode, decoded, responseBody);
      }
      return ChannelUploadResult.fromJson(
        (decoded as Map).cast<String, dynamic>(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<DirectFile> uploadDirectFile(
    String token,
    String toUserId,
    File file, {
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
    final fileName =
        originalName ??
        (file.uri.pathSegments.isEmpty ? 'upload' : file.uri.pathSegments.last);
    final uploadContentType = contentType ?? contentTypeForPath(file.path);
    final kind = uploadContentType.startsWith('image/') ? 'image' : 'file';
    final fileLength = await file.length();
    final fallbackSize = encryptionMode == 'e2ee'
        ? plaintextSizeBytes
        : fileLength;
    AttachmentUploadPlan? plan;
    try {
      plan = await initiateAttachmentUpload(
        token,
        toUserId: toUserId,
        kind: kind,
        file: file,
        originalName: fileName,
        contentType: uploadContentType,
        encryptionMode: encryptionMode,
        nonce: nonce,
        plaintextSizeBytes: plaintextSizeBytes,
        attachmentFormat: attachmentFormat,
        chunkSize: chunkSize,
        messageId: messageId,
        senderDeviceId: senderDeviceId,
        directEnvelopes: directEnvelopes,
      );
    } on OpenSpeakException catch (error) {
      if (cancelToken?.isCancelled == true) rethrow;
      if (error.statusCode != HttpStatus.notFound ||
          fallbackSize > legacyLocalAttachmentMaxBytes(kind)) {
        rethrow;
      }
    }
    if (plan?.external == true) {
      final externalPlan = plan!;
      var uploaded = false;
      try {
        await uploadExternalAttachment(
          externalPlan,
          file,
          onProgress: onProgress,
          cancelToken: cancelToken,
          contentType: uploadContentType,
        );
        uploaded = true;
      } catch (error) {
        if (cancelToken?.isCancelled == true ||
            !externalAttachmentCanFallback(
              error,
              sizeBytes: fallbackSize,
              localMaxBytes: externalPlan.localMaxBytes,
            )) {
          rethrow;
        }
        onProgress?.call(0, fileLength);
      }
      if (uploaded) {
        final completed = await request(
          'POST',
          '/api/v1/attachment-uploads/complete',
          token: token,
          body: {'completion_token': externalPlan.completionToken},
        );
        return DirectFile.fromJson((completed as Map).cast<String, dynamic>());
      }
    }
    final client = HttpClient();
    final boundary = 'openspeak-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final request = await client.openUrl(
        'POST',
        apiUri('/api/v1/direct-files'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      final toUserField =
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="to_user_id"\r\n\r\n'
          '$toUserId\r\n';
      final originalNameField =
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="original_name"\r\n\r\n'
          '$fileName\r\n';
      final encryptionFields =
          '--$boundary\r\nContent-Disposition: form-data; name="encryption_mode"\r\n\r\n$encryptionMode\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="message_id"\r\n\r\n$messageId\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="sender_device_id"\r\n\r\n$senderDeviceId\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="nonce"\r\n\r\n$nonce\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="plaintext_size_bytes"\r\n\r\n$plaintextSizeBytes\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="attachment_format"\r\n\r\n$attachmentFormat\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="chunk_size"\r\n\r\n$chunkSize\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="envelopes"\r\n\r\n${jsonEncode(directEnvelopes)}\r\n';
      final fileHeader =
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="${multipartFallbackFileName(fileName)}"\r\n'
          'Content-Type: $uploadContentType\r\n\r\n';
      final multipartFooter = '\r\n--$boundary--\r\n';
      request.contentLength =
          utf8.encode(toUserField).length +
          utf8.encode(originalNameField).length +
          utf8.encode(encryptionFields).length +
          utf8.encode(fileHeader).length +
          fileLength +
          utf8.encode(multipartFooter).length;
      void writeAscii(String value) => request.add(utf8.encode(value));

      writeAscii(toUserField);
      writeAscii(originalNameField);
      writeAscii(encryptionFields);
      writeAscii(fileHeader);
      await addFileWithProgress(
        request,
        file,
        onProgress: onProgress,
        cancelToken: cancelToken,
        cancelMessage: '上传已取消',
      );
      writeAscii(multipartFooter);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final decoded = responseBody.isEmpty ? null : jsonDecode(responseBody);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw apiException(response.statusCode, decoded, responseBody);
      }
      return DirectFile.fromJson((decoded as Map).cast<String, dynamic>());
    } finally {
      client.close(force: true);
    }
  }

  Future<AttachmentUploadPlan> initiateAttachmentUpload(
    String token, {
    String? channelId,
    String? toUserId,
    required String kind,
    required File file,
    required String originalName,
    String? contentType,
    String? encryptionMode,
    String epochId = '',
    String nonce = '',
    int plaintextSizeBytes = 0,
    String attachmentFormat = '',
    int chunkSize = 0,
    String messageId = '',
    String senderDeviceId = '',
    List<Map<String, String>> directEnvelopes = const [],
  }) async {
    final json = await request(
      'POST',
      '/api/v1/attachment-uploads',
      token: token,
      body: {
        'channel_id': ?channelId,
        'to_user_id': ?toUserId,
        'kind': kind,
        'original_name': originalName,
        'content_type': contentType ?? contentTypeForPath(file.path),
        'size_bytes': await file.length(),
        'encryption_mode': ?encryptionMode,
        'epoch_id': epochId,
        'nonce': nonce,
        'plaintext_size_bytes': plaintextSizeBytes,
        'attachment_format': attachmentFormat,
        'chunk_size': chunkSize,
        'message_id': messageId,
        'sender_device_id': senderDeviceId,
        'direct_envelopes': directEnvelopes,
      },
    );
    return AttachmentUploadPlan.fromJson((json as Map).cast<String, dynamic>());
  }

  Future<void> uploadExternalAttachment(
    AttachmentUploadPlan plan,
    File file, {
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    String? contentType,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('PUT', Uri.parse(plan.uploadUrl));
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        contentType ?? contentTypeForPath(file.path),
      );
      request.contentLength = await file.length();
      await addFileWithProgress(
        request,
        file,
        onProgress: onProgress,
        cancelToken: cancelToken,
        cancelMessage: '上传已取消',
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OpenSpeakException(
          '外部文件节点 HTTP ${response.statusCode}: $body',
          statusCode: response.statusCode,
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<File> downloadDirectFile(
    String token,
    String fileId,
    String originalName, {
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) {
    return downloadFile(
      token,
      '/api/v1/direct-files/$fileId/download',
      originalName,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<File> downloadStoredFile(
    String token,
    String fileId,
    String originalName, {
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) {
    return downloadFile(
      token,
      '/api/v1/files/$fileId/download',
      originalName,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<File> downloadFile(
    String token,
    String path,
    String originalName, {
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('GET', apiUri(path));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final responseBody = await response.transform(utf8.decoder).join();
        final decoded = responseBody.isEmpty ? null : jsonDecode(responseBody);
        final message = decoded is Map
            ? decoded['message'] ?? decoded['error']
            : responseBody;
        throw OpenSpeakException('HTTP ${response.statusCode}: $message');
      }
      final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}openspeak_downloads',
      );
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}-${sanitizeDownloadName(originalName)}',
      );
      final sink = file.openWrite();
      var transferred = 0;
      final total = response.contentLength < 0 ? 0 : response.contentLength;
      onProgress?.call(0, total);
      try {
        await for (final chunk in response) {
          cancelToken?.throwIfCancelled('下载已取消');
          sink.add(chunk);
          transferred += chunk.length;
          onProgress?.call(transferred, total);
        }
        await sink.close();
      } catch (_) {
        await sink.close();
        if (await file.exists()) {
          await file.delete();
        }
        rethrow;
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }

  Uri directFileDownloadUri(String token, String fileId) {
    return apiUri('/api/v1/direct-files/$fileId/download', {'token': token});
  }

  Uri storedFileDownloadUri(String token, String fileId) {
    return apiUri('/api/v1/files/$fileId/download', {'token': token});
  }

  Future<Uint8List> readDirectFileRange(
    String token,
    String fileId, {
    required int start,
    required int endInclusive,
  }) {
    return readFileRange(
      token,
      '/api/v1/direct-files/$fileId/download',
      start: start,
      endInclusive: endInclusive,
    );
  }

  Future<Uint8List> readStoredFileRange(
    String token,
    String fileId, {
    required int start,
    required int endInclusive,
  }) {
    return readFileRange(
      token,
      '/api/v1/files/$fileId/download',
      start: start,
      endInclusive: endInclusive,
    );
  }

  Future<Uint8List> readFileRange(
    String token,
    String path, {
    required int start,
    required int endInclusive,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final client = HttpClient();
      try {
        final request = await client.openUrl('GET', apiUri(path));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$start-$endInclusive',
        );
        final response = await request.close();
        if (response.statusCode != httpStatusPartialContent) {
          await response.drain<void>();
          throw OpenSpeakException('range request was not honored');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      } on SocketException catch (error) {
        lastError = error;
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } finally {
        client.close(force: true);
      }
    }
    throw lastError ?? OpenSpeakException('range request failed');
  }

  Future<WebSocket> openWebSocket(
    String token,
    String deviceId,
    String serverId,
  ) {
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final uri = baseUri.replace(
      scheme: scheme,
      path: '${baseUri.path}/ws',
      queryParameters: {
        'token': token,
        'device_id': deviceId,
        'server_id': serverId,
      },
    );
    return WebSocket.connect(uri.toString());
  }

  Future<dynamic> request(
    String method,
    String path, {
    String? token,
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool retryCanonicalAddress = true,
  }) async {
    var requestUri = apiUri(path, query);
    var connectAttempt = 0;
    var canonicalRetried = false;
    while (true) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        late final HttpClientRequest request;
        try {
          request = await client.openUrl(method, requestUri);
        } catch (error) {
          if (!apiConnectShouldRetry(error, connectAttempt)) rethrow;
          connectAttempt += 1;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        request.headers.contentType = ContentType.json;
        if (token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        if (body != null) {
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final responseBody = await response.transform(utf8.decoder).join();
        final decoded = responseBody.isEmpty ? null : jsonDecode(responseBody);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final retryBase = canonicalRetried || !retryCanonicalAddress
              ? null
              : canonicalServerBaseUri(baseUri, decoded);
          if (response.statusCode == HttpStatus.upgradeRequired &&
              retryBase != null) {
            baseUri = retryBase;
            requestUri = apiUri(path, query);
            connectAttempt = 0;
            canonicalRetried = true;
            continue;
          }
          throw apiException(response.statusCode, decoded, responseBody);
        }
        return decoded;
      } finally {
        client.close(force: true);
      }
    }
  }
}

OpenSpeakException apiException(
  int statusCode,
  Object? decoded,
  String fallback,
) => OpenSpeakException(
  apiExceptionMessage(statusCode, decoded, fallback),
  statusCode: statusCode,
  code: decoded is Map ? decoded['error'] as String? ?? '' : '',
  secureUrl: decoded is Map ? decoded['secure_url'] as String? ?? '' : '',
  plainUrl: decoded is Map ? decoded['plain_url'] as String? ?? '' : '',
);

String apiExceptionMessage(int statusCode, Object? decoded, String fallback) {
  if (decoded is Map && decoded['error'] == 'invalid_server_password') {
    return '服务器密码错误，请右键编辑服务器并更新密码';
  }
  final message = decoded is Map
      ? decoded['message'] ?? decoded['error']
      : fallback;
  return 'HTTP $statusCode: $message';
}

const httpStatusPartialContent = 206;

String contentTypeForPath(String path) {
  final lower = normalizedContentTypePath(path);
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.heic')) return 'image/heic';
  if (lower.endsWith('.heif')) return 'image/heif';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.aac')) return 'audio/aac';
  if (lower.endsWith('.flac')) return 'audio/flac';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.ogg')) return 'audio/ogg';
  if (lower.endsWith('.opus')) return 'audio/opus';
  if (lower.endsWith('.wma')) return 'audio/x-ms-wma';
  if (lower.endsWith('.txt')) return 'text/plain; charset=utf-8';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.zip')) return 'application/zip';
  return 'application/octet-stream';
}

String normalizedContentTypePath(String path) {
  var value = path.trim().toLowerCase();
  try {
    value = Uri.decodeFull(value);
  } catch (_) {
    // Ignore malformed percent escapes in local filenames.
  }
  final queryIndex = value.indexOf('?');
  if (queryIndex >= 0) {
    value = value.substring(0, queryIndex);
  }
  final fragmentIndex = value.indexOf('#');
  if (fragmentIndex >= 0) {
    value = value.substring(0, fragmentIndex);
  }
  while (value.isNotEmpty &&
      ' \t\r\n.,;:!?)，。；：！？）"\''.contains(value[value.length - 1])) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String sanitizeDownloadName(String value) {
  final name = value.trim().isEmpty ? 'download' : value.trim();
  final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return truncatePreservingExtension(sanitized, 160);
}

String multipartFallbackFileName(String value) {
  final sanitized = sanitizeDownloadName(
    value,
  ).replaceAll(RegExp(r'[^\x20-\x7E]'), '_').replaceAll('"', '_').trim();
  return sanitized.isEmpty ? 'upload' : sanitized;
}

String truncatePreservingExtension(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  final dot = value.lastIndexOf('.');
  if (dot <= 0 || dot == value.length - 1) {
    return value.substring(0, maxLength);
  }
  final ext = value.substring(dot);
  if (ext.length > 32 || ext.length >= maxLength) {
    return value.substring(0, maxLength);
  }
  return value.substring(0, maxLength - ext.length) + ext;
}

class OpenSpeakException implements Exception {
  OpenSpeakException(
    this.message, {
    this.statusCode = 0,
    this.code = '',
    this.secureUrl = '',
    this.plainUrl = '',
  });
  final String message;
  final int statusCode;
  final String code;
  final String secureUrl;
  final String plainUrl;

  @override
  String toString() => message;
}

class AuthSession {
  AuthSession({required this.token, required this.user});
  final String token;
  final User user;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      token: json['token'] as String,
      user: User.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}

class User {
  User({
    required this.id,
    required this.displayName,
    this.avatarVersion = 0,
    this.avatarHash = '',
  });
  final String id;
  final String displayName;
  final int avatarVersion;
  final String avatarHash;

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      displayName: json['display_name'] as String? ?? '',
      avatarVersion: json['avatar_version'] as int? ?? 0,
      avatarHash: json['avatar_hash'] as String? ?? '',
    );
  }
}

class Device {
  Device({required this.id});
  final String id;

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(id: json['id'] as String);
  }
}

class OwnerStatus {
  OwnerStatus({
    required this.claimed,
    required this.claimAvailable,
    required this.isOwner,
    this.currentOwnerDeviceId,
  });

  final bool claimed;
  final bool claimAvailable;
  final bool isOwner;
  final String? currentOwnerDeviceId;

  factory OwnerStatus.fromJson(Map<String, dynamic> json) {
    return OwnerStatus(
      claimed: json['claimed'] as bool? ?? false,
      claimAvailable: json['claim_available'] as bool? ?? false,
      isOwner: json['is_owner'] as bool? ?? false,
      currentOwnerDeviceId: json['current_owner_device_id'] as String?,
    );
  }
}

class ManagedServerMember {
  ManagedServerMember({
    required this.serverId,
    required this.userId,
    required this.displayName,
    required this.role,
    required this.online,
    required this.legacy,
    required this.banned,
    required this.installationFingerprint,
    required this.banReason,
    this.joinedAt,
    this.firstSeenAt,
    this.lastSeenAt,
    this.banExpiresAt,
  });

  final String serverId;
  final String userId;
  final String displayName;
  final String role;
  final bool online;
  final bool legacy;
  final bool banned;
  final String installationFingerprint;
  final String banReason;
  final DateTime? joinedAt;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;
  final DateTime? banExpiresAt;

  factory ManagedServerMember.fromJson(Map<String, dynamic> json) {
    return ManagedServerMember(
      serverId: json['server_id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      role: json['role'] as String? ?? 'user',
      online: json['online'] as bool? ?? false,
      legacy: json['legacy'] as bool? ?? false,
      banned: json['banned'] as bool? ?? false,
      installationFingerprint:
          json['installation_fingerprint'] as String? ?? '',
      banReason: json['ban_reason'] as String? ?? '',
      joinedAt: DateTime.tryParse(json['joined_at'] as String? ?? ''),
      firstSeenAt: DateTime.tryParse(json['first_seen_at'] as String? ?? ''),
      lastSeenAt: DateTime.tryParse(json['last_seen_at'] as String? ?? ''),
      banExpiresAt: DateTime.tryParse(json['ban_expires_at'] as String? ?? ''),
    );
  }
}

class OwnerChallenge {
  OwnerChallenge({required this.id, required this.challenge});

  final String id;
  final String challenge;

  factory OwnerChallenge.fromJson(Map<String, dynamic> json) {
    return OwnerChallenge(
      id: json['id'] as String,
      challenge: json['challenge'] as String,
    );
  }
}

class OwnerDeviceRegistration {
  OwnerDeviceRegistration({
    required this.deviceId,
    required this.publicKey,
    required this.label,
    required this.platform,
    required this.clientVersion,
  });

  final String deviceId;
  final String publicKey;
  final String label;
  final String platform;
  final String clientVersion;

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'public_key': publicKey,
    'label': label,
    'platform': platform,
    'client_version': clientVersion,
  };
}

class OwnerDeviceInfo {
  OwnerDeviceInfo({
    required this.id,
    required this.label,
    required this.platform,
    required this.clientVersion,
    required this.fingerprint,
    required this.authorizationMethod,
    required this.online,
    required this.revoked,
    this.createdAt,
    this.lastSeenAt,
  });

  final String id;
  final String label;
  final String platform;
  final String clientVersion;
  final String fingerprint;
  final String authorizationMethod;
  final bool online;
  final bool revoked;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;

  factory OwnerDeviceInfo.fromJson(Map<String, dynamic> json) {
    return OwnerDeviceInfo(
      id: json['id'] as String,
      label: json['label'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      clientVersion: json['client_version'] as String? ?? '',
      fingerprint: json['public_key_fingerprint'] as String? ?? '',
      authorizationMethod: json['authorization_method'] as String? ?? '',
      online: json['online'] as bool? ?? false,
      revoked: json['revoked_at'] != null,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      lastSeenAt: DateTime.tryParse(json['last_seen_at'] as String? ?? ''),
    );
  }
}

class OwnerAuthResult extends AuthSession {
  OwnerAuthResult({
    required super.token,
    required super.user,
    required this.ownerDevice,
  });

  final OwnerDeviceInfo ownerDevice;

  factory OwnerAuthResult.fromJson(Map<String, dynamic> json) {
    return OwnerAuthResult(
      token: json['token'] as String,
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      ownerDevice: OwnerDeviceInfo.fromJson(
        json['owner_device'] as Map<String, dynamic>,
      ),
    );
  }
}

class OwnerPairingCode {
  OwnerPairingCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime? expiresAt;

  factory OwnerPairingCode.fromJson(Map<String, dynamic> json) {
    return OwnerPairingCode(
      code: json['code'] as String,
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
    );
  }
}

class ScreenShareBitrateLimits {
  const ScreenShareBitrateLimits({
    required this.p720Fps15,
    required this.p720Fps30,
    required this.p720Fps60,
    required this.p1080Fps15,
    required this.p1080Fps30,
    required this.p1080Fps60,
    required this.sourceFps15,
    required this.sourceFps30,
    required this.sourceFps60,
  });

  static const defaults = ScreenShareBitrateLimits(
    p720Fps15: 2,
    p720Fps30: 4,
    p720Fps60: 8,
    p1080Fps15: 4,
    p1080Fps30: 8,
    p1080Fps60: 16,
    sourceFps15: 8,
    sourceFps30: 16,
    sourceFps60: 32,
  );

  final int p720Fps15;
  final int p720Fps30;
  final int p720Fps60;
  final int p1080Fps15;
  final int p1080Fps30;
  final int p1080Fps60;
  final int sourceFps15;
  final int sourceFps30;
  final int sourceFps60;

  int bitrateMbps(String resolution, int fps) => switch ((resolution, fps)) {
    ('720p', 15) => p720Fps15,
    ('720p', 30) => p720Fps30,
    ('720p', 60) => p720Fps60,
    ('1080p', 15) => p1080Fps15,
    ('1080p', 30) => p1080Fps30,
    ('1080p', 60) => p1080Fps60,
    ('source', 15) => sourceFps15,
    ('source', 30) => sourceFps30,
    ('source', 60) => sourceFps60,
    _ => 0,
  };

  Map<String, dynamic> toJson() => {
    '720p': {'15': p720Fps15, '30': p720Fps30, '60': p720Fps60},
    '1080p': {'15': p1080Fps15, '30': p1080Fps30, '60': p1080Fps60},
    'source': {'15': sourceFps15, '30': sourceFps30, '60': sourceFps60},
  };

  factory ScreenShareBitrateLimits.fromJson(Object? json) {
    final values = json is Map ? json : const {};
    int read(String resolution, int fps) {
      final row = values[resolution];
      final value = row is Map ? row['$fps'] : null;
      return value is int && value >= 1 && value <= 200
          ? value
          : defaults.bitrateMbps(resolution, fps);
    }

    return ScreenShareBitrateLimits(
      p720Fps15: read('720p', 15),
      p720Fps30: read('720p', 30),
      p720Fps60: read('720p', 60),
      p1080Fps15: read('1080p', 15),
      p1080Fps30: read('1080p', 30),
      p1080Fps60: read('1080p', 60),
      sourceFps15: read('source', 15),
      sourceFps30: read('source', 30),
      sourceFps60: read('source', 60),
    );
  }
}

class OsServer {
  OsServer({
    required this.id,
    required this.name,
    this.avatarVersion = 0,
    this.avatarHash = '',
    required this.encryptionMode,
    this.historyRetentionDays = 30,
    this.passwordProtected = false,
    this.voiceAudioBitrateKbps = 64,
    this.screenShareBitrateLimits = ScreenShareBitrateLimits.defaults,
    this.defaultChannelId,
    required this.attachmentExternalEnabled,
    this.attachmentFileNodeId,
    this.tlsCertificateType = '',
    this.tlsIdentifier = '',
    this.tlsStatus = 'disabled',
    this.tlsError = '',
    this.tlsExpiresAt,
    this.tlsRenewalAt,
  });
  final String id;
  final String name;
  final int avatarVersion;
  final String avatarHash;
  final String encryptionMode;
  final int historyRetentionDays;
  final bool passwordProtected;
  final int voiceAudioBitrateKbps;
  final ScreenShareBitrateLimits screenShareBitrateLimits;
  final String? defaultChannelId;
  final bool attachmentExternalEnabled;
  final String? attachmentFileNodeId;
  final String tlsCertificateType;
  final String tlsIdentifier;
  final String tlsStatus;
  final String tlsError;
  final DateTime? tlsExpiresAt;
  final DateTime? tlsRenewalAt;

  factory OsServer.fromJson(Map<String, dynamic> json) {
    return OsServer(
      id: json['id'] as String,
      name: json['name'] as String,
      avatarVersion: json['avatar_version'] as int? ?? 0,
      avatarHash: json['avatar_hash'] as String? ?? '',
      encryptionMode: json['encryption_mode'] as String? ?? 'none',
      historyRetentionDays: json['history_retention_days'] as int? ?? 30,
      passwordProtected: json['password_protected'] as bool? ?? false,
      voiceAudioBitrateKbps: json['voice_audio_bitrate_kbps'] as int? ?? 64,
      screenShareBitrateLimits: ScreenShareBitrateLimits.fromJson(
        json['screen_share_bitrate_limits_mbps'],
      ),
      defaultChannelId: json['default_channel_id'] as String?,
      attachmentExternalEnabled:
          json['attachment_external_enabled'] as bool? ?? false,
      attachmentFileNodeId: json['attachment_file_node_id'] as String?,
      tlsCertificateType: json['tls_certificate_type'] as String? ?? '',
      tlsIdentifier: json['tls_identifier'] as String? ?? '',
      tlsStatus: json['tls_status'] as String? ?? 'disabled',
      tlsError: json['tls_error'] as String? ?? '',
      tlsExpiresAt: DateTime.tryParse(json['tls_expires_at'] as String? ?? ''),
      tlsRenewalAt: DateTime.tryParse(json['tls_renewal_at'] as String? ?? ''),
    );
  }
}

class TlsApplyResult {
  const TlsApplyResult({
    required this.confirmationToken,
    required this.secureUrl,
    required this.expiresAt,
    required this.confirmBefore,
  });

  final String confirmationToken;
  final String secureUrl;
  final DateTime? expiresAt;
  final DateTime? confirmBefore;

  factory TlsApplyResult.fromJson(Map<String, dynamic> json) => TlsApplyResult(
    confirmationToken: json['confirmation_token'] as String? ?? '',
    secureUrl: json['secure_url'] as String? ?? '',
    expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
    confirmBefore: DateTime.tryParse(json['confirm_before'] as String? ?? ''),
  );
}

class EncryptionDowngradeResult {
  const EncryptionDowngradeResult({
    required this.confirmationToken,
    required this.plainUrl,
    required this.confirmBefore,
  });

  final String confirmationToken;
  final String plainUrl;
  final DateTime? confirmBefore;

  factory EncryptionDowngradeResult.fromJson(Map<String, dynamic> json) =>
      EncryptionDowngradeResult(
        confirmationToken: json['confirmation_token'] as String? ?? '',
        plainUrl: json['plain_url'] as String? ?? '',
        confirmBefore: DateTime.tryParse(
          json['confirm_before'] as String? ?? '',
        ),
      );
}

class AuditLogEntry {
  const AuditLogEntry({
    required this.actorUserId,
    required this.action,
    required this.targetId,
    required this.metadata,
    required this.createdAt,
  });

  final String actorUserId;
  final String action;
  final String targetId;
  final Map<String, String> metadata;
  final DateTime? createdAt;

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) => AuditLogEntry(
    actorUserId: json['actor_user_id'] as String? ?? '',
    action: json['action'] as String? ?? '',
    targetId: json['target_id'] as String? ?? '',
    metadata: (json['metadata'] as Map<String, dynamic>? ?? const {}).map(
      (key, value) => MapEntry(key, '$value'),
    ),
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
  );
}

class FileNode {
  FileNode({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.enabled,
    required this.secretSet,
  });

  final String id;
  final String name;
  final String baseUrl;
  final bool enabled;
  final bool secretSet;

  factory FileNode.fromJson(Map<String, dynamic> json) {
    return FileNode(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      baseUrl: json['base_url'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      secretSet: json['secret_set'] as bool? ?? false,
    );
  }
}

class MediaNode {
  MediaNode({
    required this.id,
    required this.name,
    required this.liveKitUrl,
    required this.apiKey,
    required this.apiSecretSet,
    required this.isLocal,
    required this.enabled,
    required this.draining,
  });

  final String id;
  final String name;
  final String liveKitUrl;
  final String apiKey;
  final bool apiSecretSet;
  final bool isLocal;
  final bool enabled;
  final bool draining;

  factory MediaNode.fromJson(Map<String, dynamic> json) {
    return MediaNode(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      liveKitUrl: json['livekit_url'] as String? ?? '',
      apiKey: json['api_key'] as String? ?? '',
      apiSecretSet: json['api_secret_set'] as bool? ?? false,
      isLocal: json['is_local'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? false,
      draining: json['draining'] as bool? ?? false,
    );
  }
}

class Channel {
  Channel({required this.id, required this.name, required this.sortOrder});
  final String id;
  final String name;
  final int sortOrder;

  factory Channel.fromJson(Map<String, dynamic> json) {
    return Channel(
      id: json['id'] as String,
      name: json['name'] as String,
      sortOrder: json['sort_order'] as int? ?? 0,
    );
  }
}

class ChannelMember {
  ChannelMember({
    required this.channelId,
    required this.userId,
    required this.role,
  });
  final String channelId;
  final String userId;
  final String role;

  factory ChannelMember.fromJson(Map<String, dynamic> json) {
    return ChannelMember(
      channelId: json['channel_id'] as String,
      userId: json['user_id'] as String,
      role: json['role'] as String? ?? 'member',
    );
  }
}

class ChannelEpoch {
  ChannelEpoch({
    required this.id,
    required this.channelId,
    required this.number,
  });

  final String id;
  final String channelId;
  final int number;

  factory ChannelEpoch.fromJson(Map<String, dynamic> json) => ChannelEpoch(
    id: json['id'] as String? ?? '',
    channelId: json['channel_id'] as String? ?? '',
    number: json['epoch_number'] as int? ?? 0,
  );
}

class ChannelE2EEDevice {
  ChannelE2EEDevice({
    required this.id,
    required this.userId,
    required this.identityPublicKey,
    required this.envelopePublicKey,
    required this.hasEnvelope,
  });

  final String id;
  final String userId;
  final String identityPublicKey;
  final String envelopePublicKey;
  final bool hasEnvelope;

  factory ChannelE2EEDevice.fromJson(Map<String, dynamic> json) =>
      ChannelE2EEDevice(
        id: json['id'] as String? ?? '',
        userId: json['user_id'] as String? ?? '',
        identityPublicKey: json['identity_public_key'] as String? ?? '',
        envelopePublicKey: json['envelope_public_key'] as String? ?? '',
        hasEnvelope: json['has_envelope'] as bool? ?? false,
      );
}

class ChannelE2EEState {
  ChannelE2EEState({
    required this.epoch,
    required this.devices,
    this.mediaKeyIndex = 0,
    this.mediaKeyActive = true,
    this.mediaKeySlots = false,
  });

  final ChannelEpoch epoch;
  final List<ChannelE2EEDevice> devices;
  final int mediaKeyIndex;
  final bool mediaKeyActive;
  final bool mediaKeySlots;

  factory ChannelE2EEState.fromJson(Map<String, dynamic> json) =>
      ChannelE2EEState(
        epoch: ChannelEpoch.fromJson(
          (json['epoch'] as Map).cast<String, dynamic>(),
        ),
        devices: listFromJson(json['devices'], ChannelE2EEDevice.fromJson),
        mediaKeyIndex: json['media_key_index'] as int? ?? 0,
        mediaKeyActive: json['media_key_active'] as bool? ?? true,
        mediaKeySlots: json['media_key_slots'] as bool? ?? false,
      );
}

class MediaKeyReady {
  MediaKeyReady({
    required this.keyIndex,
    required this.activated,
    required this.mediaKeySlots,
  });

  final int keyIndex;
  final bool activated;
  final bool mediaKeySlots;

  factory MediaKeyReady.fromJson(Map<String, dynamic> json) => MediaKeyReady(
    keyIndex: json['key_index'] as int? ?? 0,
    activated: json['activated'] as bool? ?? true,
    mediaKeySlots: json['media_key_slots'] as bool? ?? false,
  );
}

class KeyEnvelope {
  KeyEnvelope({
    required this.id,
    required this.channelId,
    required this.epochId,
    required this.recipientUserId,
    required this.recipientDeviceId,
    required this.senderDeviceId,
    required this.senderIdentityPublicKey,
    required this.algorithm,
    required this.ciphertext,
  });

  final String id;
  final String channelId;
  final String epochId;
  final String recipientUserId;
  final String recipientDeviceId;
  final String senderDeviceId;
  final String senderIdentityPublicKey;
  final String algorithm;
  final String ciphertext;

  factory KeyEnvelope.fromJson(Map<String, dynamic> json) => KeyEnvelope(
    id: json['id'] as String? ?? '',
    channelId: json['channel_id'] as String? ?? '',
    epochId: json['epoch_id'] as String? ?? '',
    recipientUserId: json['recipient_user_id'] as String? ?? '',
    recipientDeviceId: json['recipient_device_id'] as String? ?? '',
    senderDeviceId: json['sender_device_id'] as String? ?? '',
    senderIdentityPublicKey:
        json['sender_identity_public_key'] as String? ?? '',
    algorithm: json['algorithm'] as String? ?? '',
    ciphertext: json['ciphertext'] as String? ?? '',
  );
}

class KeyEnvelopeUpload {
  KeyEnvelopeUpload({
    required this.recipientUserId,
    required this.recipientDeviceId,
    required this.ciphertext,
  });

  final String recipientUserId;
  final String recipientDeviceId;
  final String ciphertext;

  Map<String, dynamic> toJson() => {
    'recipient_user_id': recipientUserId,
    'recipient_device_id': recipientDeviceId,
    'algorithm': 'openspeak-envelope-v1',
    'ciphertext': ciphertext,
  };
}

class ChannelMessage {
  ChannelMessage({
    required this.id,
    required this.channelId,
    required this.senderUserId,
    required this.senderDisplayName,
    this.senderAvatarVersion = 0,
    required this.kind,
    required this.encryptionMode,
    this.epochId = '',
    this.nonce = '',
    required this.body,
    required this.metadata,
    required this.createdAt,
  });

  final String id;
  final String channelId;
  final String senderUserId;
  final String senderDisplayName;
  final int senderAvatarVersion;
  final String kind;
  final String encryptionMode;
  final String epochId;
  final String nonce;
  final String body;
  final Map<String, String> metadata;
  final DateTime? createdAt;

  ChannelMessage withBody(String cleartext) => ChannelMessage(
    id: id,
    channelId: channelId,
    senderUserId: senderUserId,
    senderDisplayName: senderDisplayName,
    senderAvatarVersion: senderAvatarVersion,
    kind: kind,
    encryptionMode: encryptionMode,
    epochId: epochId,
    nonce: nonce,
    body: cleartext,
    metadata: metadata,
    createdAt: createdAt,
  );

  factory ChannelMessage.fromJson(Map<String, dynamic> json) {
    return ChannelMessage(
      id: json['id'] as String? ?? '',
      channelId: json['channel_id'] as String? ?? '',
      senderUserId: json['sender_user_id'] as String? ?? '',
      senderDisplayName: json['sender_display_name'] as String? ?? '',
      senderAvatarVersion: json['sender_avatar_version'] as int? ?? 0,
      kind: json['kind'] as String? ?? 'text',
      encryptionMode: json['encryption_mode'] as String? ?? 'none',
      epochId: json['epoch_id'] as String? ?? '',
      nonce: json['nonce'] as String? ?? '',
      body: json['body'] as String? ?? '',
      metadata:
          (json['metadata'] as Map?)?.map(
            (key, value) => MapEntry('$key', '$value'),
          ) ??
          const {},
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    );
  }
}

class LinkPreview {
  LinkPreview({
    required this.url,
    required this.domain,
    required this.title,
    required this.description,
    required this.imageUrl,
  });

  final String url;
  final String domain;
  final String title;
  final String description;
  final String imageUrl;

  bool get hasContent =>
      title.trim().isNotEmpty ||
      description.trim().isNotEmpty ||
      imageUrl.trim().isNotEmpty;

  factory LinkPreview.fromJson(Map<String, dynamic> json) {
    return LinkPreview(
      url: json['url'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      imageUrl: json['imageUrl'] as String? ?? '',
    );
  }
}

class AttachmentUploadPlan {
  AttachmentUploadPlan({
    required this.external,
    required this.uploadUrl,
    required this.completionToken,
    required this.localMaxBytes,
  });

  final bool external;
  final String uploadUrl;
  final String completionToken;
  final int localMaxBytes;

  factory AttachmentUploadPlan.fromJson(Map<String, dynamic> json) {
    return AttachmentUploadPlan(
      external: json['external'] as bool? ?? false,
      uploadUrl: json['upload_url'] as String? ?? '',
      completionToken: json['completion_token'] as String? ?? '',
      localMaxBytes:
          json['local_max_bytes'] as int? ?? legacyLocalAttachmentFileMaxBytes,
    );
  }
}

class StoredFile {
  StoredFile({
    required this.id,
    required this.originalName,
    required this.contentType,
    required this.sizeBytes,
  });

  final String id;
  final String originalName;
  final String contentType;
  final int sizeBytes;

  factory StoredFile.fromJson(Map<String, dynamic> json) {
    return StoredFile(
      id: json['id'] as String? ?? '',
      originalName: json['original_name'] as String? ?? '',
      contentType: json['content_type'] as String? ?? '',
      sizeBytes: json['size_bytes'] as int? ?? 0,
    );
  }
}

class ChannelUploadResult {
  ChannelUploadResult({required this.file, required this.message});

  final StoredFile file;
  final ChannelMessage message;

  factory ChannelUploadResult.fromJson(Map<String, dynamic> json) {
    return ChannelUploadResult(
      file: StoredFile.fromJson((json['file'] as Map).cast<String, dynamic>()),
      message: ChannelMessage.fromJson(
        (json['message'] as Map).cast<String, dynamic>(),
      ),
    );
  }
}

class DirectFile {
  DirectFile({
    required this.id,
    required this.serverId,
    required this.fromUserId,
    required this.toUserId,
    required this.originalName,
    required this.contentType,
    required this.sizeBytes,
    required this.expiresAt,
  });

  final String id;
  final String serverId;
  final String fromUserId;
  final String toUserId;
  final String originalName;
  final String contentType;
  final int sizeBytes;
  final DateTime? expiresAt;

  factory DirectFile.fromJson(Map<String, dynamic> json) {
    return DirectFile(
      id: json['id'] as String? ?? '',
      serverId: json['server_id'] as String? ?? '',
      fromUserId: json['from_user_id'] as String? ?? '',
      toUserId: json['to_user_id'] as String? ?? '',
      originalName: json['original_name'] as String? ?? '',
      contentType: json['content_type'] as String? ?? '',
      sizeBytes: json['size_bytes'] as int? ?? 0,
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
    );
  }
}

class PresenceSnapshot {
  PresenceSnapshot({
    required this.serverId,
    required this.users,
    required this.voiceStates,
  });
  final String serverId;
  final List<PresenceUser> users;
  final List<VoiceState> voiceStates;

  factory PresenceSnapshot.empty({String serverId = ''}) {
    return PresenceSnapshot(serverId: serverId, users: [], voiceStates: []);
  }

  factory PresenceSnapshot.fromJson(Map<String, dynamic> json) {
    return PresenceSnapshot(
      serverId: json['server_id'] as String? ?? '',
      users: listFromJson(json['users'], PresenceUser.fromJson),
      voiceStates: listFromJson(json['voice_states'], VoiceState.fromJson),
    );
  }
}

class PresenceUser {
  PresenceUser({
    required this.userId,
    required this.displayName,
    required this.role,
    required this.online,
    required this.devices,
    this.avatarVersion = 0,
    this.currentChannelId,
  });
  final String userId;
  final String displayName;
  final String role;
  final bool online;
  final List<PresenceDevice> devices;
  final int avatarVersion;
  final String? currentChannelId;

  factory PresenceUser.fromJson(Map<String, dynamic> json) {
    return PresenceUser(
      userId: json['user_id'] as String,
      displayName: json['display_name'] as String? ?? '',
      role: switch (json['role'] as String?) {
        'owner' => 'owner',
        'admin' => 'admin',
        _ => 'user',
      },
      online: json['online'] as bool? ?? false,
      devices: listFromJson(json['devices'], PresenceDevice.fromJson),
      avatarVersion: json['avatar_version'] as int? ?? 0,
      currentChannelId: json['current_channel_id'] as String?,
    );
  }
}

class ServerState {
  ServerState({
    required this.serverId,
    required this.channels,
    required this.onlineUsers,
    required this.voiceStates,
    required this.currentUser,
    required this.messageRetractWindowMinutes,
  });

  final String serverId;
  final List<Channel> channels;
  final List<PresenceUser> onlineUsers;
  final List<VoiceState> voiceStates;
  final CurrentUserState currentUser;
  final int messageRetractWindowMinutes;

  PresenceSnapshot get presence => PresenceSnapshot(
    serverId: serverId,
    users: onlineUsers,
    voiceStates: voiceStates,
  );

  factory ServerState.fromJson(Map<String, dynamic> json) {
    return ServerState(
      serverId: json['server_id'] as String? ?? '',
      channels: listFromJson(json['channels'], Channel.fromJson),
      onlineUsers: listFromJson(json['online_users'], PresenceUser.fromJson),
      voiceStates: listFromJson(json['voice_states'], VoiceState.fromJson),
      currentUser: CurrentUserState.fromJson(
        json['current_user'] as Map<String, dynamic>? ?? const {},
      ),
      messageRetractWindowMinutes:
          json['message_retract_window_minutes'] as int? ?? 30,
    );
  }
}

class CurrentUserState {
  CurrentUserState({
    required this.userId,
    required this.role,
    required this.permissions,
    this.currentChannelId,
    this.defaultChannelId,
    this.selectedChannelId,
  });

  final String userId;
  final String role;
  final Set<String> permissions;
  final String? currentChannelId;
  final String? defaultChannelId;
  final String? selectedChannelId;

  factory CurrentUserState.fromJson(Map<String, dynamic> json) {
    return CurrentUserState(
      userId: json['user_id'] as String? ?? '',
      role: json['role'] as String? ?? 'user',
      permissions: (json['permissions'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toSet(),
      currentChannelId: json['current_channel_id'] as String?,
      defaultChannelId: json['default_channel_id'] as String?,
      selectedChannelId: json['selected_channel_id'] as String?,
    );
  }
}

class ServerPermissionSettings {
  const ServerPermissionSettings({
    required this.serverId,
    required this.admin,
    required this.user,
    required this.available,
    required this.messageRetractWindowMinutes,
  });

  final String serverId;
  final Set<String> admin;
  final Set<String> user;
  final Set<String> available;
  final int messageRetractWindowMinutes;

  factory ServerPermissionSettings.fromJson(Map<String, dynamic> json) {
    Set<String> values(String key) =>
        (json[key] as List<dynamic>? ?? const []).whereType<String>().toSet();
    return ServerPermissionSettings(
      serverId: json['server_id'] as String? ?? '',
      admin: values('admin'),
      user: values('user'),
      available: values('available'),
      messageRetractWindowMinutes:
          json['message_retract_window_minutes'] as int? ?? 30,
    );
  }
}

class PresenceDevice {
  PresenceDevice({required this.deviceId});
  final String deviceId;

  factory PresenceDevice.fromJson(Map<String, dynamic> json) {
    return PresenceDevice(deviceId: json['device_id'] as String);
  }
}

class VoiceState {
  VoiceState({
    required this.serverId,
    required this.userId,
    required this.displayName,
    required this.channelId,
    required this.muted,
    required this.deafened,
    required this.speaking,
    this.screenSharing = false,
    this.screenShareResolution = '',
    this.screenShareFPS = 0,
    this.screenShareMediaNodeId = '',
  });

  final String serverId;
  final String userId;
  final String displayName;
  final String channelId;
  final bool muted;
  final bool deafened;
  final bool speaking;
  final bool screenSharing;
  final String screenShareResolution;
  final int screenShareFPS;
  final String screenShareMediaNodeId;

  factory VoiceState.fromJson(Map<String, dynamic> json) {
    return VoiceState(
      serverId: json['server_id'] as String,
      userId: json['user_id'] as String,
      displayName: json['display_name'] as String? ?? '',
      channelId: json['channel_id'] as String,
      muted: json['muted'] as bool? ?? false,
      deafened: json['deafened'] as bool? ?? false,
      speaking: json['speaking'] as bool? ?? false,
      screenSharing: json['screen_sharing'] as bool? ?? false,
      screenShareResolution: json['screen_share_resolution'] as String? ?? '',
      screenShareFPS: json['screen_share_fps'] as int? ?? 0,
      screenShareMediaNodeId:
          json['screen_share_media_node_id'] as String? ?? '',
    );
  }
}

class ScreenShareToken {
  const ScreenShareToken({
    required this.url,
    required this.token,
    required this.room,
    required this.channelId,
    required this.publisherUserId,
    required this.mediaNodeId,
    required this.e2eeRequired,
    required this.e2eeEpochId,
    required this.e2eeKeyIndex,
    required this.e2eeKeyActive,
    required this.canPublish,
    this.maxBitrateMbps = 0,
  });

  final String url;
  final String token;
  final String room;
  final String channelId;
  final String publisherUserId;
  final String mediaNodeId;
  final bool e2eeRequired;
  final String e2eeEpochId;
  final int e2eeKeyIndex;
  final bool e2eeKeyActive;
  final bool canPublish;
  final int maxBitrateMbps;

  factory ScreenShareToken.fromJson(Map<String, dynamic> json) =>
      ScreenShareToken(
        url: json['url'] as String? ?? '',
        token: json['token'] as String? ?? '',
        room: json['room'] as String? ?? '',
        channelId: json['channel_id'] as String? ?? '',
        publisherUserId: json['publisher_user_id'] as String? ?? '',
        mediaNodeId: json['media_node_id'] as String? ?? '',
        e2eeRequired: json['e2ee_required'] as bool? ?? false,
        e2eeEpochId: json['e2ee_epoch_id'] as String? ?? '',
        e2eeKeyIndex: json['e2ee_key_index'] as int? ?? 0,
        e2eeKeyActive: json['e2ee_key_active'] as bool? ?? true,
        canPublish: json['can_publish'] as bool? ?? false,
        maxBitrateMbps: switch (json['max_bitrate_mbps']) {
          final int value when value >= 1 && value <= 200 => value,
          _ => 0,
        },
      );
}

class VoiceToken {
  VoiceToken({
    required this.url,
    required this.token,
    required this.expiresAt,
    required this.room,
    required this.roomScope,
    required this.serverId,
    required this.channelId,
    required this.mediaNodeId,
    required this.voiceAudioBitrateKbps,
    required this.encryptionMode,
    required this.e2eeRequired,
    required this.e2eeEpochId,
    required this.e2eeKeyIndex,
    required this.e2eeKeyActive,
    required this.e2eeParticipantKeys,
    required this.mediaKeySlots,
    required this.canPublish,
    required this.canShareScreen,
  });
  final String url;
  final String token;
  final DateTime? expiresAt;
  final String room;
  final String roomScope;
  final String serverId;
  final String channelId;
  final String mediaNodeId;
  final int voiceAudioBitrateKbps;
  final String encryptionMode;
  final bool e2eeRequired;
  final String e2eeEpochId;
  final int e2eeKeyIndex;
  final bool e2eeKeyActive;
  final bool e2eeParticipantKeys;
  final bool mediaKeySlots;
  final bool canPublish;
  final bool canShareScreen;

  VoiceToken copyWith({
    String? channelId,
    String? e2eeEpochId,
    int? e2eeKeyIndex,
    bool? e2eeKeyActive,
    bool? e2eeParticipantKeys,
    bool? mediaKeySlots,
  }) => VoiceToken(
    url: url,
    token: token,
    expiresAt: expiresAt,
    room: room,
    roomScope: roomScope,
    serverId: serverId,
    channelId: channelId ?? this.channelId,
    mediaNodeId: mediaNodeId,
    voiceAudioBitrateKbps: voiceAudioBitrateKbps,
    encryptionMode: encryptionMode,
    e2eeRequired: e2eeRequired,
    e2eeEpochId: e2eeEpochId ?? this.e2eeEpochId,
    e2eeKeyIndex: e2eeKeyIndex ?? this.e2eeKeyIndex,
    e2eeKeyActive: e2eeKeyActive ?? this.e2eeKeyActive,
    e2eeParticipantKeys: e2eeParticipantKeys ?? this.e2eeParticipantKeys,
    mediaKeySlots: mediaKeySlots ?? this.mediaKeySlots,
    canPublish: canPublish,
    canShareScreen: canShareScreen,
  );

  factory VoiceToken.fromJson(Map<String, dynamic> json) {
    return VoiceToken(
      url: json['url'] as String? ?? '',
      token: json['token'] as String? ?? '',
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
      room: json['room'] as String? ?? '',
      roomScope: json['room_scope'] as String? ?? 'channel',
      serverId: json['server_id'] as String? ?? '',
      channelId: json['channel_id'] as String? ?? '',
      mediaNodeId: json['media_node_id'] as String? ?? '',
      voiceAudioBitrateKbps: json['voice_audio_bitrate_kbps'] as int? ?? 64,
      encryptionMode: json['encryption_mode'] as String? ?? 'none',
      e2eeRequired: json['e2ee_required'] as bool? ?? false,
      e2eeEpochId: json['e2ee_epoch_id'] as String? ?? '',
      e2eeKeyIndex: json['e2ee_key_index'] as int? ?? 0,
      e2eeKeyActive: json['e2ee_key_active'] as bool? ?? true,
      e2eeParticipantKeys: json['e2ee_participant_keys'] as bool? ?? false,
      mediaKeySlots: json['media_key_slots'] as bool? ?? false,
      canPublish: json['can_publish'] as bool? ?? true,
      canShareScreen: json['can_share_screen'] as bool? ?? false,
    );
  }
}

class RealtimeEvent {
  RealtimeEvent({
    required this.type,
    required this.serverId,
    required this.channelId,
    required this.fromUser,
    required this.toUser,
    required this.payload,
    required this.sentAt,
  });

  final String type;
  final String serverId;
  final String channelId;
  final String fromUser;
  final String toUser;
  final Map<String, dynamic> payload;
  final DateTime? sentAt;

  factory RealtimeEvent.fromJson(Map<String, dynamic> json) {
    return RealtimeEvent(
      type: json['type'] as String? ?? '',
      serverId: json['server_id'] as String? ?? '',
      channelId: json['channel_id'] as String? ?? '',
      fromUser: json['from_user'] as String? ?? '',
      toUser: json['to_user'] as String? ?? '',
      payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? {},
      sentAt: DateTime.tryParse(json['sent_at'] as String? ?? ''),
    );
  }
}

Future<void> addFileWithProgress(
  HttpClientRequest request,
  File file, {
  TransferProgress? onProgress,
  TransferCancelToken? cancelToken,
  required String cancelMessage,
}) async {
  final total = await file.length();
  var transferred = 0;
  onProgress?.call(0, total);
  await for (final chunk in file.openRead()) {
    cancelToken?.throwIfCancelled(cancelMessage);
    request.add(chunk);
    await request.flush();
    transferred += chunk.length;
    onProgress?.call(transferred, total);
  }
}

List<T> listFromJson<T>(dynamic value, T Function(Map<String, dynamic>) parse) {
  if (value is! List) return [];
  return value
      .whereType<Map>()
      .map((item) => parse(item.cast<String, dynamic>()))
      .toList();
}
