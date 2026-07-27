import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/unread_state_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unread controller owns counters and channel persistence', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = UnreadStateController()
      ..reset(serverId: 'server', userId: 'user')
      ..addChannel('channel', mention: true)
      ..addChannel('channel', mention: false)
      ..addChannel('other', mention: false)
      ..addDirect('peer');

    expect(controller.channelUnreadCounts, {'channel': 2, 'other': 1});
    expect(controller.channelMentionCounts, {'channel': 1});
    expect(controller.directUnreadCounts, {'peer': 1});
    expect(controller.totalUnreadCount, 4);
    await controller.persistenceComplete;

    final prefs = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(prefs.getString('$unreadStateKeyPrefix.server.user')!)
            as Map<String, dynamic>;
    expect(stored['channels'], {'channel': 2, 'other': 1});
    expect(stored['mentions'], {'channel': 1});
    expect(stored.containsKey('direct'), isFalse);

    final restored = UnreadStateController()
      ..reset(serverId: 'server', userId: 'user');
    restored.restoreChannels(
      (await restored.load('server', 'user'))!,
      retainChannelId: 'channel',
    );
    expect(restored.channelUnreadCounts, {'channel': 2});
    expect(restored.channelMentionCounts, {'channel': 1});
    expect(restored.directUnreadCounts, isEmpty);

    expect(restored.clearChannel('channel'), isTrue);
    expect(restored.clearChannel('channel'), isFalse);
    expect(restored.totalUnreadCount, 0);
  });
}
