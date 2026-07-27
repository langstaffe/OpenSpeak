import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'openspeak_api.dart';

const localProfileDisplayNameKey = 'openspeak.localProfileDisplayName.v1';
const localProfileAvatarPendingSyncKey =
    'openspeak.localProfileAvatarPendingSync.v1';

bool shouldUploadLocalAvatar({
  required bool pendingSync,
  required String localHash,
  required String remoteHash,
}) => pendingSync || localHash != remoteHash;

class LocalProfileService {
  LocalProfileService([this._supportDirectory]);

  final Directory? _supportDirectory;

  Future<({String? displayName, File? avatar})> load({
    required bool includeAvatar,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final displayName = prefs.getString(localProfileDisplayNameKey)?.trim();
    if (!includeAvatar) return (displayName: displayName, avatar: null);
    final avatar = await avatarStorageFile();
    return (
      displayName: displayName,
      avatar: await avatar.exists() && await avatar.length() > 0
          ? avatar
          : null,
    );
  }

  Future<({String displayName, File? avatar})?> save(
    String value, {
    File? avatarFile,
  }) async {
    final displayName = value.trim();
    if (displayName.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(localProfileDisplayNameKey, displayName);
    final avatar = avatarFile == null ? null : await persistAvatar(avatarFile);
    if (avatar != null) {
      await prefs.setBool(localProfileAvatarPendingSyncKey, true);
    }
    return (displayName: displayName, avatar: avatar);
  }

  Future<({AuthSession session, File? downloadedAvatar})> syncAvatar({
    required AuthSession session,
    required Future<User> Function(File file) upload,
    required Future<List<int>> Function() download,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final pendingSync =
        prefs.getBool(localProfileAvatarPendingSyncKey) ?? false;
    final local = await avatarStorageFile();
    if (await local.exists() && await local.length() > 0) {
      if (shouldUploadLocalAvatar(
        pendingSync: pendingSync,
        localHash: await avatarHash(local),
        remoteHash: session.user.avatarHash,
      )) {
        final user = await upload(local);
        await markAvatarSynced();
        return (
          session: AuthSession(
            token: session.token,
            user: user,
            expiresAt: session.expiresAt,
          ),
          downloadedAvatar: null,
        );
      }
      return (session: session, downloadedAvatar: null);
    }
    if (session.user.avatarVersion <= 0) {
      return (session: session, downloadedAvatar: null);
    }
    final avatar = await persistAvatarBytes(await download());
    return (session: session, downloadedAvatar: avatar);
  }

  Future<void> markAvatarSynced() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(localProfileAvatarPendingSyncKey, false);
  }

  Future<File> avatarStorageFile() async {
    final support = _supportDirectory ?? await getApplicationSupportDirectory();
    return File(
      '${support.path}${Platform.pathSeparator}profile${Platform.pathSeparator}avatar.original',
    );
  }

  Future<File> persistAvatarBytes(List<int> bytes) async {
    final target = await avatarStorageFile();
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await FileImage(target).evict();
      await target.delete();
    }
    final persisted = await temporary.rename(target.path);
    // FileImage keys are path-based. Evict again after replacement so a
    // listener that raced with the write cannot retain the previous bytes.
    await FileImage(persisted).evict();
    return persisted;
  }

  Future<File> persistAvatar(File source) async {
    final target = await avatarStorageFile();
    if (source.absolute.path == target.absolute.path) return target;
    return persistAvatarBytes(await source.readAsBytes());
  }

  Future<String> avatarHash(File file) async {
    final hash = await Sha256().hash(await file.readAsBytes());
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
