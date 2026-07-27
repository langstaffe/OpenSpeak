import 'dart:io';

import 'openspeak_api.dart';

class SavedServerConnection {
  const SavedServerConnection({
    required this.id,
    required this.name,
    required this.url,
    required this.password,
    this.serverId = '',
    this.avatarVersion = 0,
  });

  final String id;
  final String name;
  final String url;
  final String password;
  final String serverId;
  final int avatarVersion;

  factory SavedServerConnection.fromJson(Map<String, dynamic> json) {
    final url = (json['url'] as String? ?? '').trim();
    final rawName = (json['name'] as String? ?? '').trim();
    return SavedServerConnection(
      id: (json['id'] as String? ?? url.toLowerCase()).trim(),
      name: rawName.isEmpty ? displayHostPort(url) : rawName,
      url: url,
      password: json['password'] as String? ?? '',
      serverId: json['server_id'] as String? ?? '',
      avatarVersion: json['avatar_version'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'password': password,
    'server_id': serverId,
    'avatar_version': avatarVersion,
  };

  SavedServerConnection copyWith({
    String? name,
    String? url,
    String? password,
    String? serverId,
    int? avatarVersion,
  }) => SavedServerConnection(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    password: password ?? this.password,
    serverId: serverId ?? this.serverId,
    avatarVersion: avatarVersion ?? this.avatarVersion,
  );
}

String displayHostPort(String url) {
  final uri = parseServerUri(url);
  if (uri == null || uri.host.isEmpty) return url.trim();
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

Uri? savedServerAvatarUri(SavedServerConnection connection) {
  if (connection.serverId.isEmpty || connection.avatarVersion <= 0) return null;
  final base = Uri.tryParse(connection.url);
  if (base == null) return null;
  final prefix = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(
    path: '$prefix/api/v1/servers/${connection.serverId}/avatar',
    queryParameters: {'size': 'small', 'v': '${connection.avatarVersion}'},
  );
}

Uri? parseServerUri(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final candidate = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  return Uri.tryParse(candidate);
}

String serverHostFromUrl(String value) {
  final uri = parseServerUri(value);
  if (uri?.host.isNotEmpty == true) return uri!.host;
  return cleanServerHost(value);
}

String serverPortFromUrl(String value) {
  final uri = parseServerUri(value);
  if (uri != null && uri.hasPort) return '${uri.port}';
  if (uri?.scheme.toLowerCase() == 'https') return '443';
  return '27410';
}

String cleanServerHost(String value) {
  var host = value.trim();
  if (host.contains('://')) {
    final uri = Uri.tryParse(host);
    if (uri?.host.isNotEmpty == true) return uri!.host;
  }
  host = host.split('/').first.trim();
  if (host.startsWith('[')) {
    final end = host.indexOf(']');
    if (end > 0) return host.substring(1, end);
  }
  final lastColon = host.lastIndexOf(':');
  if (lastColon > 0 && host.indexOf(':') == lastColon) {
    final maybePort = host.substring(lastColon + 1);
    if (int.tryParse(maybePort) != null) {
      host = host.substring(0, lastColon);
    }
  }
  return host;
}

String serverBaseUrl({
  required String host,
  required String port,
  String scheme = 'http',
}) {
  final cleanHost = cleanServerHost(host);
  final parsedPort = int.tryParse(port.trim());
  final enteredScheme = Uri.tryParse(host.trim())?.scheme.toLowerCase();
  final effectiveScheme =
      scheme.toLowerCase() == 'https' ||
          enteredScheme == 'https' ||
          parsedPort == 443
      ? 'https'
      : 'http';
  final bracketedHost = cleanHost.contains(':') && !cleanHost.startsWith('[')
      ? '[$cleanHost]'
      : cleanHost;
  return '$effectiveScheme://$bracketedHost:${parsedPort ?? 27410}';
}

String serverConnectionUrl({
  required String host,
  required int port,
  required String previousScheme,
}) => serverBaseUrl(
  host: cleanServerHost(host),
  port: '$port',
  scheme: port == 27410 ? 'http' : previousScheme,
);

String externalFileNodeUrl({
  required String host,
  required String port,
  String path = '/files',
}) {
  final cleanHost = cleanServerHost(host);
  final parsedPort = int.tryParse(port.trim());
  if (cleanHost.isEmpty ||
      parsedPort == null ||
      parsedPort < 1 ||
      parsedPort > 65535) {
    throw OpenSpeakException('请填写有效的外部服务器 IP、域名和端口');
  }
  final suffix = path.isEmpty || path == '/'
      ? ''
      : path.startsWith('/')
      ? path
      : '/$path';
  return '${serverBaseUrl(host: cleanHost, port: '$parsedPort', scheme: 'https')}$suffix';
}

String externalLiveKitUrl({
  required String host,
  required String port,
  String path = '',
}) {
  final cleanHost = cleanServerHost(host);
  final parsedPort = int.tryParse(port.trim());
  if (cleanHost.isEmpty ||
      parsedPort == null ||
      parsedPort < 1 ||
      parsedPort > 65535) {
    throw OpenSpeakException('请填写有效的 LiveKit 服务器 IP、域名和端口');
  }
  final suffix = path.isEmpty || path == '/'
      ? ''
      : path.startsWith('/')
      ? path
      : '/$path';
  final bracketedHost = cleanHost.contains(':') ? '[$cleanHost]' : cleanHost;
  final result = 'wss://$bracketedHost:$parsedPort$suffix';
  final uri = Uri.tryParse(result);
  if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) {
    throw OpenSpeakException('请填写有效的 LiveKit 服务器 IP、域名和端口');
  }
  return result;
}

Future<File> ensureServerAvatarCached({
  required Directory cacheDir,
  required String serverId,
  required int avatarVersion,
  required Future<List<int>> Function() download,
}) async {
  final safeServerId = sanitizeDownloadName(serverId);
  final target = File(
    '${cacheDir.path}${Platform.pathSeparator}$safeServerId-$avatarVersion.original',
  );
  if (await target.exists() && await target.length() > 0) return target;
  final bytes = await download();
  if (bytes.isEmpty) throw OpenSpeakException('服务器头像下载为空');
  await cacheDir.create(recursive: true);
  final temporary = File('${target.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
  await for (final entry in cacheDir.list()) {
    if (entry is File &&
        entry.path != target.path &&
        entry.uri.pathSegments.last.startsWith('$safeServerId-')) {
      await entry.delete();
    }
  }
  return target;
}
