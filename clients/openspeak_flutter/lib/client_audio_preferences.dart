import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'microphone_activation.dart';

const audioInputDeviceKey = 'openspeak.audioInputDeviceId.v1';
const audioOutputDeviceKey = 'openspeak.audioOutputDeviceId.v1';
const audioInputVolumeKey = 'openspeak.audioInputVolume.v1';
const audioOutputVolumeKey = 'openspeak.audioOutputVolume.v1';
const soundEffectVolumeKey = 'openspeak.soundEffectVolume.v1';
const microphoneActivationModeKey = 'openspeak.microphoneActivationMode.v1';
const microphoneThresholdKey = 'openspeak.microphoneThreshold.v1';
const microphonePushToTalkHotkeyKey = 'openspeak.microphonePushToTalkHotkey.v1';
const noiseSuppressionEnabledKey = 'openspeak.noiseSuppressionEnabled.v1';
const memberOutputVolumesKey = 'openspeak.memberOutputVolumes.v1';

typedef AudioPreferenceValues = ({
  String? inputDeviceId,
  String? outputDeviceId,
  double inputVolume,
  double outputVolume,
  double soundEffectVolume,
  bool noiseSuppressionEnabled,
  MicrophoneActivationMode activationMode,
  double microphoneThreshold,
  MicrophoneHotkeyBinding? pushToTalkHotkey,
});

class ClientAudioPreferences {
  Future<AudioPreferenceValues> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedActivationMode = MicrophoneActivationModeValue.parse(
      prefs.getString(microphoneActivationModeKey),
    );
    final activationMode = microphoneActivationModeForPlatform(
      savedActivationMode,
    );
    if (activationMode != savedActivationMode) {
      await prefs.setString(
        microphoneActivationModeKey,
        activationMode.preferenceValue,
      );
    }
    return (
      inputDeviceId: _deviceId(prefs.getString(audioInputDeviceKey)),
      outputDeviceId: _deviceId(prefs.getString(audioOutputDeviceKey)),
      inputVolume: _volume(prefs.getDouble(audioInputVolumeKey), 1.0),
      outputVolume: _volume(prefs.getDouble(audioOutputVolumeKey), 1.0),
      soundEffectVolume: _volume(prefs.getDouble(soundEffectVolumeKey), 1.0),
      noiseSuppressionEnabled:
          prefs.getBool(noiseSuppressionEnabledKey) ?? true,
      activationMode: activationMode,
      microphoneThreshold: _volume(
        prefs.getDouble(microphoneThresholdKey),
        0.4,
      ),
      pushToTalkHotkey: _hotkey(prefs.getString(microphonePushToTalkHotkeyKey)),
    );
  }

  Future<Map<String, double>?> loadMemberOutputVolumes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(memberOutputVolumesKey);
    if (raw == null || raw.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final volumes = <String, double>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is! num) continue;
      final volume = value.toDouble().clamp(0.0, 2.0).toDouble();
      if (volume != 1.0) volumes['${entry.key}'] = volume;
    }
    return volumes;
  }

  Future<void> saveDeviceSelection({
    required String? inputDeviceId,
    required String? outputDeviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _saveDeviceId(prefs, audioInputDeviceKey, inputDeviceId);
    await _saveDeviceId(prefs, audioOutputDeviceKey, outputDeviceId);
  }

  Future<void> saveInputVolume(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(audioInputVolumeKey, value.clamp(0.0, 1.0));
  }

  Future<void> saveOutputVolume(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(audioOutputVolumeKey, value.clamp(0.0, 1.0));
  }

  Future<void> saveNoiseSuppression(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(noiseSuppressionEnabledKey, enabled);
  }

  Future<void> saveMemberOutputVolumes(Map<String, double> volumes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(memberOutputVolumesKey, jsonEncode(volumes));
  }

  Future<void> saveAudioSettings({
    required MicrophoneActivationMode activationMode,
    required double microphoneThreshold,
    required MicrophoneHotkeyBinding? pushToTalkHotkey,
    required double soundEffectVolume,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      microphoneActivationModeKey,
      activationMode.preferenceValue,
    );
    await prefs.setDouble(
      microphoneThresholdKey,
      microphoneThreshold.clamp(0.0, 1.0),
    );
    await prefs.setDouble(
      soundEffectVolumeKey,
      soundEffectVolume.clamp(0.0, 1.0),
    );
    if (pushToTalkHotkey == null) {
      await prefs.remove(microphonePushToTalkHotkeyKey);
    } else {
      await prefs.setString(
        microphonePushToTalkHotkeyKey,
        jsonEncode(pushToTalkHotkey.toJson()),
      );
    }
  }
}

String? _deviceId(String? value) =>
    value?.trim().isEmpty == true ? null : value;

double _volume(double? value, double fallback) =>
    (value ?? fallback).clamp(0.0, 1.0).toDouble();

MicrophoneHotkeyBinding? _hotkey(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    return MicrophoneHotkeyBinding.fromJson(jsonDecode(value));
  } catch (_) {
    return null;
  }
}

Future<void> _saveDeviceId(
  SharedPreferences prefs,
  String key,
  String? value,
) => value == null || value.isEmpty
    ? prefs.remove(key)
    : prefs.setString(key, value);
