import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/client_session_store.dart';
import 'package:openspeak_flutter/openspeak_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('client installation ID is generated once and reused', () async {
    SharedPreferences.setMockInitialValues({});

    final first = await loadOrCreateClientInstallationId();
    final second = await loadOrCreateClientInstallationId();
    final stored = (await SharedPreferences.getInstance()).getString(
      clientInstallationIdKey,
    );

    expect(second, first);
    expect(stored, first);
  });

  test('client installation IDs are UUIDv4 values', () {
    final first = generateClientInstallationId();
    final second = generateClientInstallationId();
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );

    expect(first, matches(uuid));
    expect(second, matches(uuid));
    expect(second, isNot(first));
  });

  test('Web auth sessions are cached and cleared', () {
    clearWebAuthSession();
    addTearDown(clearWebAuthSession);
    final session = AuthSession(
      token: 'token',
      user: User(id: 'user', displayName: 'User'),
      expiresAt: DateTime.utc(2099),
    );

    cacheWebAuthSession(session);
    expect(loadWebAuthSession()?.token, session.token);

    clearWebAuthSession();
    expect(loadWebAuthSession(), isNull);
  }, skip: !kIsWeb);
}
