import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

enum MicrophoneActivationMode { pushToTalk, continuous, voiceThreshold }

const _windowsMicrophoneLevelChannel = MethodChannel(
  'openspeak/microphone_level',
);
const _windowsMicrophoneLevelEvents = EventChannel(
  'openspeak/microphone_level/events',
);

bool windowsMicrophoneLevelSupported(
  TargetPlatform platform, {
  bool isWeb = false,
}) => !isWeb && platform == TargetPlatform.windows;

String? resolvedMicrophoneTrackDeviceId(
  lk.LocalAudioTrack track, {
  String? fallback,
}) {
  final resolved = track.mediaStreamTrack.getSettings()['deviceId'];
  if (resolved is String && resolved.isNotEmpty) return resolved;
  return fallback == null || fallback.isEmpty ? null : fallback;
}

class WindowsMicrophoneLevelMonitor {
  WindowsMicrophoneLevelMonitor() : _monitorId = 'monitor-${_nextMonitorId++}';

  static int _nextMonitorId = 1;
  static final Stream<dynamic> _events = _windowsMicrophoneLevelEvents
      .receiveBroadcastStream();

  final String _monitorId;
  StreamSubscription<dynamic>? _subscription;
  int _generation = 0;

  Future<bool> start({
    String? deviceId,
    String? trackId,
    bool useWebRtc = false,
    required ValueChanged<double> onRms,
  }) async {
    if (!windowsMicrophoneLevelSupported(
      defaultTargetPlatform,
      isWeb: kIsWeb,
    )) {
      return false;
    }
    final generation = ++_generation;
    await _subscription?.cancel();
    _subscription = _events.listen((event) {
      if (generation != _generation || event is! Map) return;
      if (event['monitor_id'] != _monitorId) return;
      final rms = event['rms'];
      if (rms is num) onRms(rms.toDouble().clamp(0.0, 1.0).toDouble());
    });
    final retryDelays = useWebRtc
        ? const [Duration.zero]
        : const [
            Duration.zero,
            Duration(milliseconds: 60),
            Duration(milliseconds: 150),
            Duration(milliseconds: 300),
          ];
    for (final delay in retryDelays) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (generation != _generation) return false;
      try {
        final started =
            await _windowsMicrophoneLevelChannel.invokeMethod<bool>('start', {
              'monitor_id': _monitorId,
              'device_id': deviceId ?? '',
              'track_id': trackId ?? '',
              'source': useWebRtc ? 'webrtc' : 'wasapi',
            }) ==
            true;
        if (generation != _generation) return false;
        if (started) return true;
      } catch (_) {
        // Windows runner support is optional in non-desktop test environments.
      }
    }
    if (generation == _generation) {
      await _subscription?.cancel();
      _subscription = null;
    }
    return false;
  }

  Future<void> stop() async {
    _generation++;
    await _subscription?.cancel();
    _subscription = null;
    if (!windowsMicrophoneLevelSupported(
      defaultTargetPlatform,
      isWeb: kIsWeb,
    )) {
      return;
    }
    try {
      await _windowsMicrophoneLevelChannel.invokeMethod<void>('stop', {
        'monitor_id': _monitorId,
      });
    } catch (_) {
      // Best-effort cleanup during shutdown and in non-Windows tests.
    }
  }
}

extension MicrophoneActivationModeValue on MicrophoneActivationMode {
  String get preferenceValue => switch (this) {
    MicrophoneActivationMode.pushToTalk => 'push_to_talk',
    MicrophoneActivationMode.continuous => 'continuous',
    MicrophoneActivationMode.voiceThreshold => 'voice_threshold',
  };

  static MicrophoneActivationMode parse(String? value) => switch (value) {
    'push_to_talk' => MicrophoneActivationMode.pushToTalk,
    'voice_threshold' => MicrophoneActivationMode.voiceThreshold,
    _ => MicrophoneActivationMode.continuous,
  };
}

MicrophoneActivationMode microphoneActivationModeForPlatform(
  MicrophoneActivationMode saved, {
  bool isWeb = kIsWeb,
}) => isWeb ? MicrophoneActivationMode.continuous : saved;

class MicrophoneHotkeyBinding {
  const MicrophoneHotkeyBinding({
    required this.usbHidUsage,
    required this.modifiers,
    required this.label,
  });

  static const controlModifier = 1;
  static const altModifier = 2;
  static const shiftModifier = 4;
  static const metaModifier = 8;

  final int usbHidUsage;
  final int modifiers;
  final String label;

  Map<String, Object> toJson() => {
    'usb_hid_usage': usbHidUsage,
    'modifiers': modifiers,
    'label': label,
  };

  static MicrophoneHotkeyBinding? fromJson(Object? value) {
    if (value is! Map) return null;
    final usage = value['usb_hid_usage'];
    final modifiers = value['modifiers'];
    final label = value['label'];
    if (usage is! num || modifiers is! num || label is! String) return null;
    if (usage <= 0 || label.trim().isEmpty) return null;
    return MicrophoneHotkeyBinding(
      usbHidUsage: usage.toInt(),
      modifiers: modifiers.toInt(),
      label: label.trim(),
    );
  }
}

class GlobalPushToTalkHotkey extends ChangeNotifier {
  GlobalPushToTalkHotkey() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const _channel = MethodChannel('openspeak/global_push_to_talk');

  bool _pressed = false;
  bool _registered = false;
  bool _accessibilityPermissionRequired = false;
  String? _error;

  bool get pressed => _pressed;
  bool get registered => _registered;
  bool get accessibilityPermissionRequired => _accessibilityPermissionRequired;
  String? get error => _error;

  Future<bool> register(MicrophoneHotkeyBinding binding) async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      _registered = false;
      _accessibilityPermissionRequired = false;
      _error = '当前平台暂不支持系统级按键通话';
      notifyListeners();
      return false;
    }
    try {
      final registered =
          await _channel.invokeMethod<bool>('register', {
            'usb_hid_usage': binding.usbHidUsage,
            'modifiers': binding.modifiers,
          }) ??
          false;
      _registered = registered;
      _accessibilityPermissionRequired = false;
      _error = registered ? null : '无法注册这个系统级快捷键';
      if (!registered) _setPressed(false);
      notifyListeners();
      return registered;
    } on PlatformException catch (error) {
      _registered = false;
      _accessibilityPermissionRequired =
          error.code == 'accessibility_permission_required';
      _error = error.message ?? '无法注册系统级快捷键';
      _setPressed(false);
      notifyListeners();
      return false;
    } on MissingPluginException {
      _registered = false;
      _accessibilityPermissionRequired = false;
      _error = '当前客户端不包含系统级按键通话支持';
      _setPressed(false);
      notifyListeners();
      return false;
    }
  }

  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (_) {
      // Clearing is best-effort during shutdown or on unsupported platforms.
    }
    _registered = false;
    _accessibilityPermissionRequired = false;
    _error = null;
    _setPressed(false);
    notifyListeners();
  }

  Future<void> openAccessibilitySettings() async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } catch (_) {}
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'pressed') return;
    _setPressed(call.arguments == true);
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    _pressed = value;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_channel.invokeMethod<void>('clear').catchError((_) {}));
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

bool isModifierPhysicalKey(PhysicalKeyboardKey key) =>
    key == PhysicalKeyboardKey.controlLeft ||
    key == PhysicalKeyboardKey.controlRight ||
    key == PhysicalKeyboardKey.altLeft ||
    key == PhysicalKeyboardKey.altRight ||
    key == PhysicalKeyboardKey.shiftLeft ||
    key == PhysicalKeyboardKey.shiftRight ||
    key == PhysicalKeyboardKey.metaLeft ||
    key == PhysicalKeyboardKey.metaRight;

int currentHotkeyModifiers() {
  final pressed = HardwareKeyboard.instance.physicalKeysPressed;
  var modifiers = 0;
  if (pressed.contains(PhysicalKeyboardKey.controlLeft) ||
      pressed.contains(PhysicalKeyboardKey.controlRight)) {
    modifiers |= MicrophoneHotkeyBinding.controlModifier;
  }
  if (pressed.contains(PhysicalKeyboardKey.altLeft) ||
      pressed.contains(PhysicalKeyboardKey.altRight)) {
    modifiers |= MicrophoneHotkeyBinding.altModifier;
  }
  if (pressed.contains(PhysicalKeyboardKey.shiftLeft) ||
      pressed.contains(PhysicalKeyboardKey.shiftRight)) {
    modifiers |= MicrophoneHotkeyBinding.shiftModifier;
  }
  if (pressed.contains(PhysicalKeyboardKey.metaLeft) ||
      pressed.contains(PhysicalKeyboardKey.metaRight)) {
    modifiers |= MicrophoneHotkeyBinding.metaModifier;
  }
  return modifiers;
}

String hotkeyLabel(PhysicalKeyboardKey key, int modifiers) {
  return hotkeyLabelFromUsbHidUsage(
    key.usbHidUsage,
    modifiers,
    fallback: key.debugName,
  );
}

String hotkeyBindingLabel(MicrophoneHotkeyBinding binding) {
  return hotkeyLabelFromUsbHidUsage(
    binding.usbHidUsage,
    binding.modifiers,
    fallback: binding.label,
  );
}

String hotkeyLabelFromUsbHidUsage(
  int usbHidUsage,
  int modifiers, {
  String? fallback,
}) {
  final parts = <String>[];
  if ((modifiers & MicrophoneHotkeyBinding.controlModifier) != 0) {
    parts.add(Platform.isMacOS ? '⌃' : 'Ctrl');
  }
  if ((modifiers & MicrophoneHotkeyBinding.altModifier) != 0) {
    parts.add(Platform.isMacOS ? '⌥' : 'Alt');
  }
  if ((modifiers & MicrophoneHotkeyBinding.shiftModifier) != 0) {
    parts.add(Platform.isMacOS ? '⇧' : 'Shift');
  }
  if ((modifiers & MicrophoneHotkeyBinding.metaModifier) != 0) {
    parts.add(Platform.isMacOS ? '⌘' : 'Win');
  }
  final fallbackLabel = fallback?.trim();
  parts.add(
    _physicalKeyName(usbHidUsage) ??
        (fallbackLabel == null ||
                fallbackLabel.isEmpty ||
                fallbackLabel.startsWith('按键 ')
            ? '未知按键'
            : fallbackLabel),
  );
  return parts.join(Platform.isMacOS ? ' ' : ' + ');
}

String? _physicalKeyName(int usbHidUsage) {
  final usagePage = usbHidUsage >> 16;
  final usage = usbHidUsage & 0xffff;
  if (usagePage != 0x07) return null;
  if (usage >= 0x04 && usage <= 0x1d) {
    return String.fromCharCode('A'.codeUnitAt(0) + usage - 0x04);
  }
  if (usage >= 0x1e && usage <= 0x26) return '${usage - 0x1d}';
  if (usage == 0x27) return '0';
  if (usage >= 0x3a && usage <= 0x45) return 'F${usage - 0x39}';
  if (usage >= 0x59 && usage <= 0x61) return '小键盘 ${usage - 0x58}';
  return const {
    0x28: 'Enter',
    0x29: 'Esc',
    0x2a: 'Backspace',
    0x2b: 'Tab',
    0x2c: 'Space',
    0x2d: '-',
    0x2e: '=',
    0x2f: '[',
    0x30: ']',
    0x31: r'\',
    0x33: ';',
    0x34: "'",
    0x35: '`',
    0x36: ',',
    0x37: '.',
    0x38: '/',
    0x39: 'Caps Lock',
    0x46: 'Print Screen',
    0x47: 'Scroll Lock',
    0x48: 'Pause',
    0x49: 'Insert',
    0x4a: 'Home',
    0x4b: 'Page Up',
    0x4c: 'Delete',
    0x4d: 'End',
    0x4e: 'Page Down',
    0x4f: '→',
    0x50: '←',
    0x51: '↓',
    0x52: '↑',
    0x53: 'Num Lock',
    0x54: '小键盘 /',
    0x55: '小键盘 *',
    0x56: '小键盘 -',
    0x57: '小键盘 +',
    0x58: '小键盘 Enter',
    0x62: '小键盘 0',
    0x63: '小键盘 .',
    0x65: 'Menu',
  }[usage];
}

class MicrophoneInputLevelPreview extends ChangeNotifier
    implements ValueListenable<double> {
  MicrophoneInputLevelPreview({required this.fallbackLevel}) {
    fallbackLevel.addListener(_fallbackChanged);
  }

  final ValueListenable<double> fallbackLevel;
  lk.LocalAudioTrack? _track;
  lk.CancelListenFunc? _removeAudioRenderer;
  final WindowsMicrophoneLevelMonitor _windowsLevelMonitor =
      WindowsMicrophoneLevelMonitor();
  double _previewLevel = 0;
  int _generation = 0;
  bool _disposed = false;
  Future<void>? _startOperation;

  @override
  double get value => math.max(fallbackLevel.value, _previewLevel);

  Future<void> start({String? deviceId}) {
    final generation = ++_generation;
    final operation = _startCapture(generation, deviceId: deviceId);
    _startOperation = operation;
    return operation.whenComplete(() {
      if (identical(_startOperation, operation)) _startOperation = null;
    });
  }

  Future<void> _startCapture(int generation, {String? deviceId}) async {
    await _releaseCapture();
    try {
      final track = await lk.LocalAudioTrack.create(
        lk.AudioCaptureOptions(
          deviceId: deviceId == null || deviceId.isEmpty ? null : deviceId,
          echoCancellation: true,
          autoGainControl: true,
          noiseSuppression: true,
          stopAudioCaptureOnMute: false,
        ),
      );
      if (generation != _generation) {
        await track.stop();
        return;
      }
      if (windowsMicrophoneLevelSupported(
        defaultTargetPlatform,
        isWeb: kIsWeb,
      )) {
        _track = track;
        final started = await _windowsLevelMonitor.start(
          deviceId: resolvedMicrophoneTrackDeviceId(track, fallback: deviceId),
          onRms: (rms) {
            if (!_disposed && generation == _generation) {
              _updatePreviewLevel(rms);
            }
          },
        );
        if (generation != _generation) {
          await _windowsLevelMonitor.stop();
          await track.stop();
          if (identical(_track, track)) _track = null;
          return;
        }
        if (!started) {
          throw StateError('Windows microphone monitor unavailable');
        }
        return;
      }
      final removeRenderer = track.addAudioRenderer(
        options: const lk.AudioRendererOptions(
          sampleRate: 24000,
          channels: 1,
          format: lk.AudioFormat.Int16,
        ),
        onFrame: (frame) => _handleAudioFrame(frame, generation),
      );
      if (generation != _generation) {
        await removeRenderer();
        await track.stop();
        return;
      }
      _track = track;
      _removeAudioRenderer = removeRenderer;
    } catch (_) {
      if (generation == _generation) await _releaseCapture();
    }
  }

  Future<void> stop() async {
    _generation++;
    await _releaseCapture();
    final pendingStart = _startOperation;
    if (pendingStart != null) await pendingStart;
    // A capture that was already inside getUserMedia when stop began releases
    // itself after observing the generation change. Run cleanup once more so
    // callers can safely start LiveKit immediately after this Future completes.
    await _releaseCapture();
  }

  void _handleAudioFrame(lk.AudioFrame frame, int generation) {
    if (_disposed || generation != _generation) return;
    _updatePreviewLevel(microphonePcmRms(frame));
  }

  void _updatePreviewLevel(double rms) {
    final next = microphoneLevelFromRms(rms);
    if ((_previewLevel - next).abs() >= 0.01 || next == 0) {
      _previewLevel = next;
      notifyListeners();
    }
  }

  void _fallbackChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _releaseCapture() async {
    await _windowsLevelMonitor.stop();
    final removeRenderer = _removeAudioRenderer;
    _removeAudioRenderer = null;
    await removeRenderer?.call();
    final track = _track;
    _track = null;
    await track?.stop();
    if (_previewLevel != 0) {
      _previewLevel = 0;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    fallbackLevel.removeListener(_fallbackChanged);
    unawaited(stop());
    super.dispose();
  }
}

double microphonePcmRms(lk.AudioFrame frame) {
  final bytes = frame.data;
  if (frame.format != lk.AudioFormat.Int16 || bytes.length < 2) return 0;
  final data = ByteData.sublistView(bytes);
  var sumSquares = 0.0;
  var samples = 0;
  for (var offset = 0; offset + 1 < bytes.length; offset += 2) {
    final sample = data.getInt16(offset, Endian.little) / 32768.0;
    sumSquares += sample * sample;
    samples += 1;
  }
  return math.sqrt(sumSquares / samples);
}

double microphoneThresholdDb(double value) => -50 + value.clamp(0.0, 1.0) * 100;

String microphoneThresholdLabel(double value) {
  final threshold = microphoneThresholdDb(value).round();
  return '${threshold > 0 ? '+' : ''}$threshold dB';
}

double _microphoneThresholdDbfs(double value) =>
    -60 + value.clamp(0.0, 1.0) * 50;

double microphoneThresholdRms(double value) =>
    math.pow(10, _microphoneThresholdDbfs(value) / 20).toDouble();

double microphoneLevelFromRms(double rms) {
  if (rms <= 0) return 0;
  final db = 20 * math.log(rms) / math.ln10;
  return ((db + 60) / 50).clamp(0.0, 1.0).toDouble();
}
