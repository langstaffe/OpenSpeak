import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import 'browser_actions.dart';
import 'openspeak_api.dart';

const clientInstallationIdKey = 'openspeak.clientInstallationId.v1';
const webAuthSessionStorageKey = 'openspeak.webAuthSession.v1';

String generateClientInstallationId() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Future<String> loadOrCreateClientInstallationId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(clientInstallationIdKey)?.trim() ?? '';
  if (existing.isNotEmpty) return existing;
  final created = generateClientInstallationId();
  await prefs.setString(clientInstallationIdKey, created);
  return created;
}

AuthSession? loadWebAuthSession() => kIsWeb
    ? AuthSession.fromStorage(readBrowserSessionValue(webAuthSessionStorageKey))
    : null;

void clearWebAuthSession() {
  if (kIsWeb) removeBrowserSessionValue(webAuthSessionStorageKey);
}

void cacheWebAuthSession(AuthSession auth) {
  if (!kIsWeb || auth.expiresAt == null) return;
  writeBrowserSessionValue(webAuthSessionStorageKey, jsonEncode(auth));
}
