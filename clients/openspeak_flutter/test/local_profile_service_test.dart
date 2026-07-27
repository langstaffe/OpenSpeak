import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/local_profile_service.dart';
import 'package:openspeak_flutter/openspeak_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDirectory;
  late LocalProfileService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    supportDirectory = await Directory.systemTemp.createTemp(
      'openspeak_profile_test_',
    );
    service = LocalProfileService(supportDirectory);
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test('local profile saves and loads its trimmed name and avatar', () async {
    final source = File('${supportDirectory.path}/source.png');
    await source.writeAsBytes([1, 2, 3]);

    final saved = await service.save('  Alice  ', avatarFile: source);
    final loaded = await service.load(includeAvatar: true);
    final prefs = await SharedPreferences.getInstance();

    expect(saved?.displayName, 'Alice');
    expect(await saved?.avatar?.readAsBytes(), [1, 2, 3]);
    expect(loaded.displayName, 'Alice');
    expect(await loaded.avatar?.readAsBytes(), [1, 2, 3]);
    expect(prefs.getBool(localProfileAvatarPendingSyncKey), isTrue);
  });

  test('pending local avatar uploads even when its hash matches', () async {
    final source = File('${supportDirectory.path}/source.png');
    await source.writeAsBytes([4, 5, 6]);
    final saved = await service.save('Alice', avatarFile: source);
    final auth = AuthSession(
      token: 'token',
      user: User(
        id: 'user',
        displayName: 'Alice',
        avatarVersion: 1,
        avatarHash: await service.avatarHash(saved!.avatar!),
      ),
    );
    var uploads = 0;

    final result = await service.syncAvatar(
      session: auth,
      upload: (file) async {
        uploads += 1;
        expect(await file.readAsBytes(), [4, 5, 6]);
        return User(
          id: 'user',
          displayName: 'Alice',
          avatarVersion: 2,
          avatarHash: 'uploaded',
        );
      },
      download: () => throw StateError('download should not run'),
    );
    final prefs = await SharedPreferences.getInstance();

    expect(uploads, 1);
    expect(result.session.user.avatarHash, 'uploaded');
    expect(result.downloadedAvatar, isNull);
    expect(prefs.getBool(localProfileAvatarPendingSyncKey), isFalse);
  });

  test('remote avatar downloads when no local avatar exists', () async {
    final auth = AuthSession(
      token: 'token',
      user: User(
        id: 'user',
        displayName: 'Alice',
        avatarVersion: 2,
        avatarHash: 'remote',
      ),
    );

    final result = await service.syncAvatar(
      session: auth,
      upload: (_) => throw StateError('upload should not run'),
      download: () async => [7, 8, 9],
    );

    expect(identical(result.session, auth), isTrue);
    expect(await result.downloadedAvatar?.readAsBytes(), [7, 8, 9]);
    expect(
      await (await service.load(includeAvatar: true)).avatar?.readAsBytes(),
      [7, 8, 9],
    );
  });

  test('avatar upload decision preserves offline changes', () {
    expect(
      shouldUploadLocalAvatar(
        pendingSync: true,
        localHash: 'same',
        remoteHash: 'same',
      ),
      isTrue,
    );
    expect(
      shouldUploadLocalAvatar(
        pendingSync: false,
        localHash: 'same',
        remoteHash: 'same',
      ),
      isFalse,
    );
    expect(
      shouldUploadLocalAvatar(
        pendingSync: false,
        localHash: 'new',
        remoteHash: 'old',
      ),
      isTrue,
    );
  });
}
