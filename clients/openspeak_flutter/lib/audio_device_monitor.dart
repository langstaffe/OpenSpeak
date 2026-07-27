import 'dart:async';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'client_log.dart';

typedef AudioDeviceEnumerator = Future<List<rtc.MediaDeviceInfo>> Function();
typedef AudioDeviceChangeRegistrar =
    void Function(Function(dynamic event)? listener);

Duration audioDevicePollInterval(TargetPlatform _) => Duration.zero;

const _nativeAudioDeviceChannel = MethodChannel('openspeak/audio_devices');

void registerAudioDeviceChangeListener(Function(dynamic)? listener) {
  rtc.navigator.mediaDevices.ondevicechange = listener;
  if (defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.windows) {
    return;
  }
  if (listener == null) {
    _nativeAudioDeviceChannel.setMethodCallHandler(null);
    return;
  }
  _nativeAudioDeviceChannel.setMethodCallHandler((call) async {
    if (call.method == 'changed') listener(null);
  });
}

class AudioDeviceMonitor extends ChangeNotifier {
  factory AudioDeviceMonitor({
    required AudioDeviceEnumerator enumerateDevices,
    required AudioDeviceChangeRegistrar registerDeviceChangeListener,
    Duration emptyRetryDelay = const Duration(milliseconds: 200),
    int maxEmptyRetries = 4,
    Duration pollInterval = Duration.zero,
    List<Duration> deviceChangeProbeDelays = const [
      Duration(milliseconds: 200),
      Duration(milliseconds: 500),
      Duration(milliseconds: 1000),
    ],
  }) => AudioDeviceMonitor._(
    enumerateDevices,
    registerDeviceChangeListener,
    emptyRetryDelay,
    maxEmptyRetries,
    pollInterval,
    deviceChangeProbeDelays,
  );

  AudioDeviceMonitor._(
    this._enumerateDevices,
    this._registerDeviceChangeListener,
    this._emptyRetryDelay,
    this._maxEmptyRetries,
    this._pollInterval,
    this._deviceChangeProbeDelays,
  );

  final AudioDeviceEnumerator _enumerateDevices;
  final AudioDeviceChangeRegistrar _registerDeviceChangeListener;
  final Duration _emptyRetryDelay;
  final int _maxEmptyRetries;
  final Duration _pollInterval;
  final List<Duration> _deviceChangeProbeDelays;
  List<rtc.MediaDeviceInfo> _devices = const [];
  Object? _error;
  bool _hasLoaded = false;
  bool _lastRefreshSucceeded = false;
  bool _audioInputDevicesChanged = false;
  bool _started = false;
  bool _disposed = false;
  int _refreshGeneration = 0;
  Future<void>? _refreshInFlight;
  int _consecutiveEmptyResults = 0;
  Timer? _emptyRetryTimer;
  Timer? _pollTimer;
  final List<Timer> _deviceChangeProbeTimers = [];
  int _deviceChangeGeneration = 0;

  List<rtc.MediaDeviceInfo> get devices => _devices;
  Object? get error => _error;
  bool get hasLoaded => _hasLoaded;
  bool get lastRefreshSucceeded => _lastRefreshSucceeded;
  bool get audioInputDevicesChanged => _audioInputDevicesChanged;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _registerDeviceChangeListener(_onDeviceChange);
    await refresh();
    if (!_disposed && _pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(refresh()));
    }
  }

  Future<void> refresh({bool stabilizationProbe = false}) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    late final Future<void> refresh;
    refresh = _refresh(stabilizationProbe: stabilizationProbe).whenComplete(() {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
    });
    _refreshInFlight = refresh;
    return refresh;
  }

  Future<void> _refresh({bool stabilizationProbe = false}) async {
    if (_disposed) return;
    if (!stabilizationProbe) {
      _emptyRetryTimer?.cancel();
      _emptyRetryTimer = null;
    }
    final generation = ++_refreshGeneration;
    try {
      final nextDevices = await _enumerateDevices();
      if (_disposed || generation != _refreshGeneration) return;
      final hasAudioDevice = nextDevices.any(
        (device) => device.kind == 'audioinput' || device.kind == 'audiooutput',
      );
      if (!hasAudioDevice && stabilizationProbe) return;
      if (!hasAudioDevice && _consecutiveEmptyResults < _maxEmptyRetries) {
        _consecutiveEmptyResults += 1;
        _emptyRetryTimer = Timer(
          _emptyRetryDelay * _consecutiveEmptyResults,
          () => unawaited(refresh()),
        );
        return;
      }
      _emptyRetryTimer?.cancel();
      _emptyRetryTimer = null;
      _consecutiveEmptyResults = 0;
      final audioInputDevicesChanged =
          _hasLoaded &&
          !_sameAudioDevices(
            _devices
                .where((device) => device.kind == 'audioinput')
                .toList(growable: false),
            nextDevices
                .where((device) => device.kind == 'audioinput')
                .toList(growable: false),
          );
      final changed =
          !_hasLoaded ||
          _error != null ||
          !_lastRefreshSucceeded ||
          !_sameAudioDevices(_devices, nextDevices);
      _devices = List<rtc.MediaDeviceInfo>.unmodifiable(nextDevices);
      _audioInputDevicesChanged = audioInputDevicesChanged;
      _error = null;
      _hasLoaded = true;
      _lastRefreshSucceeded = true;
      if (changed) {
        final inputs = nextDevices
            .where((device) => device.kind == 'audioinput')
            .map((device) => '${device.deviceId}:${device.label}')
            .join(',');
        ClientLog.write('audio.devices', 'refresh inputs=[$inputs]');
        notifyListeners();
      }
    } catch (error, stackTrace) {
      if (_disposed || generation != _refreshGeneration) return;
      _audioInputDevicesChanged = false;
      _error = error;
      _lastRefreshSucceeded = false;
      ClientLog.error('audio.devices', error, stackTrace);
      notifyListeners();
    }
  }

  void _onDeviceChange(dynamic event) {
    ClientLog.write('audio.devices', 'native change event');
    _scheduleRefreshAfterDeviceChange();
  }

  void _scheduleRefreshAfterDeviceChange() {
    final deviceChangeGeneration = ++_deviceChangeGeneration;
    for (final timer in _deviceChangeProbeTimers) {
      timer.cancel();
    }
    _deviceChangeProbeTimers.clear();

    // CoreAudio can abort inside getSources while its device notification is
    // still being processed. Probe shortly after the native callback returns.
    for (final delay in _deviceChangeProbeDelays) {
      late final Timer timer;
      timer = Timer(delay, () {
        _deviceChangeProbeTimers.remove(timer);
        if (_disposed || deviceChangeGeneration != _deviceChangeGeneration) {
          return;
        }
        unawaited(refresh(stabilizationProbe: true));
      });
      _deviceChangeProbeTimers.add(timer);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _refreshGeneration += 1;
    _deviceChangeGeneration += 1;
    _emptyRetryTimer?.cancel();
    _emptyRetryTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final timer in _deviceChangeProbeTimers) {
      timer.cancel();
    }
    _deviceChangeProbeTimers.clear();
    if (_started) _registerDeviceChangeListener(null);
    super.dispose();
  }
}

bool _sameAudioDevices(
  List<rtc.MediaDeviceInfo> left,
  List<rtc.MediaDeviceInfo> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    final a = left[index];
    final b = right[index];
    if (a.deviceId != b.deviceId || a.kind != b.kind || a.label != b.label) {
      return false;
    }
  }
  return true;
}

({String? inputDeviceId, String? outputDeviceId})
audioDeviceSelectionAfterRefresh({
  required String? inputDeviceId,
  required String? outputDeviceId,
  required Iterable<rtc.MediaDeviceInfo> devices,
}) {
  final normalizedInputDeviceId = _isWebRtcDefaultDeviceId(inputDeviceId)
      ? null
      : inputDeviceId;
  final normalizedOutputDeviceId = _isWebRtcDefaultDeviceId(outputDeviceId)
      ? null
      : outputDeviceId;
  final inputAvailable =
      normalizedInputDeviceId == null ||
      devices.any(
        (device) =>
            device.kind == 'audioinput' &&
            device.deviceId == normalizedInputDeviceId,
      );
  final outputAvailable =
      normalizedOutputDeviceId == null ||
      devices.any(
        (device) =>
            device.kind == 'audiooutput' &&
            device.deviceId == normalizedOutputDeviceId,
      );
  return (
    inputDeviceId: inputAvailable ? normalizedInputDeviceId : null,
    outputDeviceId: outputAvailable ? normalizedOutputDeviceId : null,
  );
}

bool _isWebRtcDefaultDeviceId(String? deviceId) =>
    deviceId?.trim().toLowerCase() == 'default';

bool isWebRtcVirtualDefaultAudioDevice(rtc.MediaDeviceInfo device) {
  final label = device.label.trim().toLowerCase();
  return _isWebRtcDefaultDeviceId(device.deviceId) ||
      label.startsWith('default (');
}

String? webRtcDefaultAudioDeviceName(
  Iterable<rtc.MediaDeviceInfo> devices,
  String kind,
) {
  for (final device in devices) {
    if (device.kind != kind || !isWebRtcVirtualDefaultAudioDevice(device)) {
      continue;
    }
    final label = device.label.trim();
    final lowerLabel = label.toLowerCase();
    if (lowerLabel.startsWith('default (') && label.endsWith(')')) {
      final name = label.substring('default ('.length, label.length - 1).trim();
      if (name.isNotEmpty) return name;
    }
    if (label.isNotEmpty && lowerLabel != 'default') return label;
  }
  for (final device in devices) {
    if (device.kind == kind &&
        !isWebRtcVirtualDefaultAudioDevice(device) &&
        device.label.trim().isNotEmpty) {
      return device.label.trim();
    }
  }
  return null;
}

String systemDefaultAudioDeviceLabel(
  Iterable<rtc.MediaDeviceInfo> devices,
  String kind,
  String baseLabel,
) {
  final currentDevice = webRtcDefaultAudioDeviceName(devices, kind);
  return currentDevice == null ? baseLabel : '$baseLabel($currentDevice)';
}

List<rtc.MediaDeviceInfo> selectableAudioDevices(
  Iterable<rtc.MediaDeviceInfo> devices,
  String kind,
) => devices
    .where(
      (device) =>
          device.kind == kind && !isWebRtcVirtualDefaultAudioDevice(device),
    )
    .toList(growable: false);

bool audioDeviceKindUnavailable(AudioDeviceMonitor monitor, String kind) =>
    monitor.hasLoaded && !monitor.devices.any((device) => device.kind == kind);
