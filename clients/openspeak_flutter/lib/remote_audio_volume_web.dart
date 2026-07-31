import 'dart:async';
import 'dart:js_interop';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;

final Map<String, _GainRoute> _gainRoutes = {};
final Map<String, Object> _pendingGainRoutes = {};
final Map<String, double> _blockedGainVolumes = {};
web.AudioContext? _audioContext;
web.EventListener? _resumeListener;

Future<void> setRemoteAudioTrackVolume(
  lk.RemoteAudioTrack track,
  double volume,
) => setRemoteAudioElementVolume(track.getCid(), volume);

Future<void> setRemoteAudioElementVolume(String trackId, double volume) async {
  _pendingGainRoutes.remove(trackId);
  _blockedGainVolumes.remove(trackId);
  final element = web.document.getElementById('livekit_audio_$trackId');
  if (element == null || !element.instanceOfString('HTMLAudioElement')) return;

  final audio = element as web.HTMLAudioElement;
  final next = volume.clamp(0.0, 2.0).toDouble();
  var route = _gainRoutes[trackId];
  if (route != null && audio.srcObject != route.destination.stream) {
    route.dispose();
    _gainRoutes.remove(trackId);
    route = null;
  }
  if (route != null) {
    if (next > 1) {
      route.gain.gain.value = next;
      return;
    }
    audio.srcObject = route.input;
    route.dispose();
    _gainRoutes.remove(trackId);
    audio.volume = next;
    return;
  }
  if (next <= 1) {
    audio.volume = next;
    return;
  }

  final input = audio.srcObject;
  if (input == null || !input.instanceOfString('MediaStream')) return;
  audio.volume = 1;
  final context = _audioContext ??= web.AudioContext();
  if (context.state != 'running') {
    if (!web.window.navigator.userActivation.isActive) {
      _retryGainAfterUserInteraction(trackId, next);
      return;
    }
    final pendingRoute = Object();
    _pendingGainRoutes[trackId] = pendingRoute;
    try {
      await context.resume().toDart;
    } catch (_) {
      if (identical(_pendingGainRoutes[trackId], pendingRoute)) {
        _pendingGainRoutes.remove(trackId);
        _retryGainAfterUserInteraction(trackId, next);
      }
      return;
    }
    if (!identical(_pendingGainRoutes[trackId], pendingRoute)) return;
    _pendingGainRoutes.remove(trackId);
    if (web.document.getElementById('livekit_audio_$trackId') != element ||
        audio.srcObject != input) {
      return setRemoteAudioElementVolume(trackId, next);
    }
  }
  if (context.state != 'running') {
    _retryGainAfterUserInteraction(trackId, next);
    return;
  }

  final inputStream = input as web.MediaStream;
  final source = context.createMediaStreamSource(inputStream);
  final gain = context.createGain()..gain.value = next;
  final destination = context.createMediaStreamDestination();
  source.connect(gain);
  gain.connect(destination);
  audio
    ..volume = 1
    ..srcObject = destination.stream;
  _gainRoutes[trackId] = _GainRoute(inputStream, source, gain, destination);
  _blockedGainVolumes.remove(trackId);
}

void _retryGainAfterUserInteraction(String trackId, double volume) {
  _blockedGainVolumes[trackId] = volume;
  if (_resumeListener != null) return;
  _resumeListener = ((web.Event _) {
    final listener = _resumeListener;
    if (listener != null) {
      web.document.removeEventListener('pointerup', listener);
      web.document.removeEventListener('keydown', listener);
      web.document.removeEventListener('click', listener);
    }
    _resumeListener = null;
    final pending = Map.of(_blockedGainVolumes);
    _blockedGainVolumes.clear();
    for (final entry in pending.entries) {
      unawaited(setRemoteAudioElementVolume(entry.key, entry.value));
    }
  }).toJS;
  web.document.addEventListener('pointerup', _resumeListener);
  web.document.addEventListener('keydown', _resumeListener);
  web.document.addEventListener('click', _resumeListener);
}

class _GainRoute {
  _GainRoute(this.input, this.source, this.gain, this.destination);

  final web.MediaStream input;
  final web.MediaStreamAudioSourceNode source;
  final web.GainNode gain;
  final web.MediaStreamAudioDestinationNode destination;

  void dispose() {
    source.disconnect();
    gain.disconnect();
    destination.disconnect();
  }
}
