import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'client_log.dart';

enum SoundEffect {
  memberJoin('sounds/member_join.wav'),
  memberLeave('sounds/member_leave.wav'),
  micMute('sounds/mic_mute.wav'),
  micUnmute('sounds/mic_unmute.wav'),
  listenOff('sounds/listen_off.wav'),
  listenOn('sounds/listen_on.wav'),
  mutedSpeaking('sounds/muted_speaking.wav'),
  screenShareStart('sounds/screen_share_start.wav'),
  screenShareStop('sounds/screen_share_stop.wav'),
  messageSend('sounds/message_send.wav'),
  messageChannel('sounds/message_channel.wav'),
  messageDirect('sounds/message_direct.wav'),
  voiceDisconnect('sounds/voice_disconnect.wav'),
  voiceReconnect('sounds/voice_reconnect.wav'),
  error('sounds/error.wav');

  const SoundEffect(this.asset);

  final String asset;

  int get priority => switch (this) {
    SoundEffect.error ||
    SoundEffect.mutedSpeaking ||
    SoundEffect.voiceDisconnect => 3,
    SoundEffect.micMute ||
    SoundEffect.micUnmute ||
    SoundEffect.listenOff ||
    SoundEffect.listenOn ||
    SoundEffect.voiceReconnect => 2,
    SoundEffect.screenShareStart ||
    SoundEffect.screenShareStop ||
    SoundEffect.messageSend ||
    SoundEffect.messageChannel ||
    SoundEffect.messageDirect => 1,
    SoundEffect.memberJoin || SoundEffect.memberLeave => 0,
  };
}

class SoundEffectPlayer {
  final AudioPlayer _player = AudioPlayer();
  final Map<SoundEffect, DateTime> _lastPlayed = {};
  double _volume = 1;
  DateTime _playingUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _playingPriority = -1;

  double get volume => _volume;

  set volume(double value) => _volume = value.clamp(0.0, 1.0).toDouble();

  Future<void> play(
    SoundEffect effect, {
    double? volume,
    Duration cooldown = Duration.zero,
  }) async {
    final gain = (volume ?? _volume).clamp(0.0, 1.0).toDouble();
    if (gain == 0) return;
    final now = DateTime.now();
    final previous = _lastPlayed[effect];
    if (previous != null && now.difference(previous) < cooldown) return;
    if (now.isBefore(_playingUntil) && effect.priority < _playingPriority) {
      return;
    }
    _lastPlayed[effect] = now;
    _playingPriority = effect.priority;
    _playingUntil = now.add(const Duration(milliseconds: 400));
    try {
      await _player.play(
        AssetSource(effect.asset),
        volume: gain,
        mode: PlayerMode.lowLatency,
      );
    } catch (error, stackTrace) {
      ClientLog.error('sound.${effect.name}', error, stackTrace);
    }
  }

  Future<void> dispose() => _player.dispose();
}

class MutedSpeechReminder {
  MutedSpeechReminder(this.onWarning);

  static const firstDelay = Duration(milliseconds: 1500);
  static const repeatDelay = Duration(seconds: 10);
  static const resetDelay = Duration(seconds: 2);

  final void Function() onWarning;
  Timer? _firstTimer;
  Timer? _repeatTimer;
  Timer? _resetTimer;
  bool _eligible = false;
  bool _active = false;
  bool _episodeStarted = false;

  void update({
    required bool muted,
    required bool listenOff,
    required bool active,
  }) {
    _eligible = muted && !listenOff;
    _active = active;
    if (!_eligible) {
      reset();
      return;
    }
    if (active) {
      _resetTimer?.cancel();
      _resetTimer = null;
      if (_episodeStarted) return;
      _episodeStarted = true;
      _firstTimer = Timer(firstDelay, _startWarnings);
      return;
    }
    if (_episodeStarted && _resetTimer == null) {
      _resetTimer = Timer(resetDelay, reset);
    }
  }

  void _startWarnings() {
    _firstTimer = null;
    if (!_eligible || !_episodeStarted) return;
    if (_active) onWarning();
    _repeatTimer = Timer.periodic(repeatDelay, (_) {
      if (_eligible && _active) onWarning();
    });
  }

  void reset() {
    _firstTimer?.cancel();
    _repeatTimer?.cancel();
    _resetTimer?.cancel();
    _firstTimer = null;
    _repeatTimer = null;
    _resetTimer = null;
    _episodeStarted = false;
  }

  void dispose() => reset();
}
