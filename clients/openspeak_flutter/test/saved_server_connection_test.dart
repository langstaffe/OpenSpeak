import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/saved_server_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'saved server connections round trip in order and filter by URL',
    () async {
      SharedPreferences.setMockInitialValues({});
      const first = SavedServerConnection(
        id: 'first',
        name: 'First',
        url: 'https://first.example',
        password: 'one',
        serverId: 'server-1',
        avatarVersion: 2,
      );
      const second = SavedServerConnection(
        id: 'second',
        name: 'Second',
        url: 'https://second.example',
        password: 'two',
      );

      await saveSavedServerConnections([first, second]);

      expect(
        (await loadSavedServerConnections())
            ?.map((item) => item.toJson())
            .toList(),
        [first.toJson(), second.toJson()],
      );
      expect(
        (await loadSavedServerConnections(
          onlyUrl: second.url,
        ))?.map((item) => item.id).toList(),
        ['second'],
      );
    },
  );

  test('damaged saved entries do not discard valid connections', () async {
    SharedPreferences.setMockInitialValues({
      savedConnectionsKey: jsonEncode([
        {
          'id': 'valid',
          'name': 'Valid',
          'url': 'https://valid.example',
          'password': '',
        },
        {'url': 7},
        {'url': ''},
        'invalid',
      ]),
    });

    final loaded = await loadSavedServerConnections();

    expect(loaded?.map((item) => item.id).toList(), ['valid']);
  });

  test('malformed saved connection JSON is ignored', () async {
    SharedPreferences.setMockInitialValues({savedConnectionsKey: '{broken'});

    expect(await loadSavedServerConnections(), isNull);
  });
}
