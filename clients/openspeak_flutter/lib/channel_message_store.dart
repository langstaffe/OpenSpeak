import 'openspeak_api.dart';

class ChannelMessageStore {
  final messages = <ChannelMessage>[];
  var _loadGeneration = 0;
  bool loading = false;

  int beginLoad() {
    loading = true;
    return ++_loadGeneration;
  }

  bool isCurrent(int generation) => generation == _loadGeneration;

  void finishLoad(int generation) {
    if (isCurrent(generation)) loading = false;
  }

  void replaceHistory(
    int generation,
    Iterable<ChannelMessage> history, {
    required String channelId,
    required bool Function(String messageId) isPending,
  }) {
    if (!isCurrent(generation)) return;
    final optimistic = messages
        .where(
          (message) => message.channelId == channelId && isPending(message.id),
        )
        .toList();
    messages
      ..clear()
      ..addAll(history)
      ..addAll(optimistic);
  }

  void add(ChannelMessage message) => messages.add(message);

  void addOrReplace(ChannelMessage message) {
    final index = messages.indexWhere((item) => item.id == message.id);
    if (index >= 0) {
      messages[index] = message;
    } else {
      messages.add(message);
    }
  }

  void remove(String messageId) {
    messages.removeWhere((message) => message.id == messageId);
  }

  void reset() {
    _loadGeneration += 1;
    loading = false;
    messages.clear();
  }
}
