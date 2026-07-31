@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/remote_audio_volume_web.dart';
import 'package:web/web.dart' as web;

void main() {
  test('member volume controls the LiveKit Web playback element', () async {
    final audio = web.HTMLAudioElement()
      ..id = 'livekit_audio_remote-track'
      ..volume = 1;
    web.document.body!.append(audio);
    addTearDown(() => audio.remove());

    await setRemoteAudioElementVolume('remote-track', 0);

    expect(audio.volume, 0);

    final inputContext = web.AudioContext();
    final oscillator = inputContext.createOscillator();
    final inputDestination = inputContext.createMediaStreamDestination();
    oscillator.connect(inputDestination);
    oscillator.start();
    addTearDown(() async {
      oscillator.stop();
      oscillator.disconnect();
      inputDestination.disconnect();
      await inputContext.close().toDart;
    });
    audio.srcObject = inputDestination.stream;

    await setRemoteAudioElementVolume('remote-track', 2);

    expect(audio.volume, 1);

    await setRemoteAudioElementVolume('remote-track', .5);

    expect(audio.volume, .5);
    expect(audio.srcObject == inputDestination.stream, isTrue);
  });
}
