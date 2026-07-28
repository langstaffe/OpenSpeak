import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/channel_message_store.dart';
import 'package:openspeak_flutter/openspeak_api.dart';

void main() {
  test(
    'channel message store rejects stale loads and keeps optimistic items',
    () {
      final store = ChannelMessageStore();
      final firstLoad = store.beginLoad();
      store.add(channelMessage('local', channelId: 'channel'));
      store.add(channelMessage('foreign', channelId: 'other'));

      store.replaceHistory(
        firstLoad,
        [channelMessage('remote', channelId: 'channel')],
        channelId: 'channel',
        isPending: (_) => true,
      );
      expect(store.messages.map((message) => message.id), ['remote', 'local']);

      final secondLoad = store.beginLoad();
      expect(store.isCurrent(firstLoad), isFalse);
      expect(store.isCurrent(secondLoad), isTrue);
      store.replaceHistory(
        firstLoad,
        [channelMessage('stale', channelId: 'channel')],
        channelId: 'channel',
        isPending: (_) => false,
      );
      expect(store.messages.map((message) => message.id), ['remote', 'local']);
      store.finishLoad(firstLoad);
      expect(store.loading, isTrue);
      store.finishLoad(secondLoad);
      expect(store.loading, isFalse);

      store.addOrReplace(channelMessage('local', channelId: 'channel'));
      expect(
        store.messages.where((message) => message.id == 'local'),
        hasLength(1),
      );
      store.remove('local');
      expect(store.messages.map((message) => message.id), ['remote']);

      store.reset();
      expect(store.messages, isEmpty);
      expect(store.isCurrent(secondLoad), isFalse);
    },
  );
}

ChannelMessage channelMessage(String id, {required String channelId}) =>
    ChannelMessage(
      id: id,
      channelId: channelId,
      senderUserId: 'sender',
      senderDisplayName: 'Sender',
      kind: 'text',
      encryptionMode: 'none',
      body: id,
      metadata: const {},
      createdAt: DateTime.utc(2026, 7, 18),
    );
