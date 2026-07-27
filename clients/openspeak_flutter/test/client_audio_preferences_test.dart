import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/client_audio_preferences.dart';
import 'package:openspeak_flutter/microphone_activation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientAudioPreferences preferences;

  setUp(() {
    preferences = ClientAudioPreferences();
  });

  test('loads existing audio preferences with validation', () async {
    SharedPreferences.setMockInitialValues({
      audioInputDeviceKey: '   ',
      audioOutputDeviceKey: 'speaker',
      audioInputVolumeKey: -0.5,
      audioOutputVolumeKey: 1.5,
      soundEffectVolumeKey: 0.25,
      noiseSuppressionEnabledKey: false,
      microphoneActivationModeKey: 'voice_threshold',
      microphoneThresholdKey: 2.0,
      microphonePushToTalkHotkeyKey: jsonEncode({
        'usb_hid_usage': 42,
        'modifiers': 1,
        'label': ' K ',
      }),
      memberOutputVolumesKey: jsonEncode({
        'quiet': 0.25,
        'normal': 1,
        'loud': 3,
        'invalid': 'value',
      }),
    });

    final loaded = await preferences.load();
    final memberVolumes = await preferences.loadMemberOutputVolumes();

    expect(loaded.inputDeviceId, isNull);
    expect(loaded.outputDeviceId, 'speaker');
    expect(loaded.inputVolume, 0);
    expect(loaded.outputVolume, 1);
    expect(loaded.soundEffectVolume, 0.25);
    expect(loaded.noiseSuppressionEnabled, isFalse);
    expect(loaded.activationMode, MicrophoneActivationMode.voiceThreshold);
    expect(loaded.microphoneThreshold, 1);
    expect(loaded.pushToTalkHotkey?.usbHidUsage, 42);
    expect(loaded.pushToTalkHotkey?.modifiers, 1);
    expect(loaded.pushToTalkHotkey?.label, 'K');
    expect(memberVolumes, {'quiet': 0.25, 'loud': 2.0});
  });

  test('saves audio preferences with the existing keys', () async {
    SharedPreferences.setMockInitialValues({
      audioInputDeviceKey: 'old-input',
      audioOutputDeviceKey: 'old-output',
      microphonePushToTalkHotkeyKey: 'old-hotkey',
    });
    const hotkey = MicrophoneHotkeyBinding(
      usbHidUsage: 99,
      modifiers: 4,
      label: 'Y',
    );

    await preferences.saveDeviceSelection(
      inputDeviceId: null,
      outputDeviceId: '',
    );
    await preferences.saveInputVolume(-1);
    await preferences.saveOutputVolume(2);
    await preferences.saveNoiseSuppression(false);
    await preferences.saveAudioSettings(
      activationMode: MicrophoneActivationMode.pushToTalk,
      microphoneThreshold: -1,
      pushToTalkHotkey: hotkey,
      soundEffectVolume: 2,
    );
    await preferences.saveMemberOutputVolumes({'member': 1.5});

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(audioInputDeviceKey), isFalse);
    expect(prefs.containsKey(audioOutputDeviceKey), isFalse);
    expect(prefs.getDouble(audioInputVolumeKey), 0);
    expect(prefs.getDouble(audioOutputVolumeKey), 1);
    expect(prefs.getBool(noiseSuppressionEnabledKey), isFalse);
    expect(
      prefs.getString(microphoneActivationModeKey),
      MicrophoneActivationMode.pushToTalk.preferenceValue,
    );
    expect(prefs.getDouble(microphoneThresholdKey), 0);
    expect(prefs.getDouble(soundEffectVolumeKey), 1);
    expect(
      jsonDecode(prefs.getString(microphonePushToTalkHotkeyKey)!),
      hotkey.toJson(),
    );
    expect(jsonDecode(prefs.getString(memberOutputVolumesKey)!), {
      'member': 1.5,
    });

    await preferences.saveAudioSettings(
      activationMode: MicrophoneActivationMode.continuous,
      microphoneThreshold: 0.4,
      pushToTalkHotkey: null,
      soundEffectVolume: 1,
    );
    expect(prefs.containsKey(microphonePushToTalkHotkeyKey), isFalse);
  });
}
