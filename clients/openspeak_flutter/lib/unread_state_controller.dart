import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const unreadStateKeyPrefix = 'openspeak.unreadState.v1';

typedef StoredUnreadState = ({
  Map<String, int> channels,
  Map<String, int> mentions,
});

Map<String, int> positiveIntMapFromJson(Object? value) {
  if (value is! Map) return {};
  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value is int && entry.value > 0)
        entry.key as String: entry.value as int,
  };
}

class UnreadStateController {
  final channelUnreadCounts = <String, int>{};
  final channelMentionCounts = <String, int>{};
  final directUnreadCounts = <String, int>{};

  String? _serverId;
  String? _userId;
  Future<void> _persistence = Future.value();

  int get totalUnreadCount =>
      channelUnreadCounts.values.fold<int>(0, (sum, value) => sum + value) +
      directUnreadCounts.values.fold<int>(0, (sum, value) => sum + value);

  Future<void> get persistenceComplete => _persistence;

  void reset({String? serverId, String? userId}) {
    _serverId = serverId;
    _userId = userId;
    channelUnreadCounts.clear();
    channelMentionCounts.clear();
    directUnreadCounts.clear();
  }

  Future<StoredUnreadState?> load(String serverId, String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$unreadStateKeyPrefix.$serverId.$userId';
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return (
        channels: positiveIntMapFromJson(decoded['channels']),
        mentions: positiveIntMapFromJson(decoded['mentions']),
      );
    } catch (_) {
      await prefs.remove(key);
      return null;
    }
  }

  void restoreChannels(StoredUnreadState state, {String? retainChannelId}) {
    channelUnreadCounts
      ..clear()
      ..addEntries(
        state.channels.entries.where((entry) => entry.key == retainChannelId),
      );
    channelMentionCounts
      ..clear()
      ..addEntries(
        state.mentions.entries.where((entry) => entry.key == retainChannelId),
      );
  }

  bool clearChannel(String channelId) {
    final removedUnread = channelUnreadCounts.remove(channelId) != null;
    final removedMention = channelMentionCounts.remove(channelId) != null;
    if (removedUnread || removedMention) _persist();
    return removedUnread || removedMention;
  }

  bool retainChannelOnly(String channelId) {
    final unreadLength = channelUnreadCounts.length;
    final mentionLength = channelMentionCounts.length;
    channelUnreadCounts.removeWhere((key, _) => key != channelId);
    channelMentionCounts.removeWhere((key, _) => key != channelId);
    final changed =
        channelUnreadCounts.length != unreadLength ||
        channelMentionCounts.length != mentionLength;
    if (changed) _persist();
    return changed;
  }

  void addChannel(String channelId, {required bool mention}) {
    channelUnreadCounts[channelId] = (channelUnreadCounts[channelId] ?? 0) + 1;
    if (mention) {
      channelMentionCounts[channelId] =
          (channelMentionCounts[channelId] ?? 0) + 1;
    }
    _persist();
  }

  bool clearDirect(String userId) => directUnreadCounts.remove(userId) != null;

  void addDirect(String userId) {
    directUnreadCounts[userId] = (directUnreadCounts[userId] ?? 0) + 1;
  }

  void _persist() {
    final serverId = _serverId;
    final userId = _userId;
    if (serverId == null || userId == null) return;
    final raw = jsonEncode({
      'channels': channelUnreadCounts,
      'mentions': channelMentionCounts,
    });
    _persistence = _persistence
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('$unreadStateKeyPrefix.$serverId.$userId', raw);
        })
        .catchError((_) {});
  }
}
