import 'dart:async';
import 'dart:js_interop';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamTrackWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;

import 'client_log.dart';

const _processorName = '@sapphi-red/web-noise-suppressor/rnnoise';
const _workletPath = 'rnnoise/workletProcessor.js';
const _wasmPath = 'rnnoise/rnnoise.wasm';

lk.TrackProcessor<lk.AudioProcessorOptions>? createRnnoiseAudioProcessor() =>
    _RnnoiseAudioProcessor();

extension type _RnnoiseProcessorOptions._(JSObject _) implements JSObject {
  external factory _RnnoiseProcessorOptions({
    required int maxChannels,
    required JSArrayBuffer wasmBinary,
  });
}

class _RnnoiseAudioProcessor
    implements lk.TrackProcessor<lk.AudioProcessorOptions> {
  rtc.MediaStreamTrack? _inputTrack;
  rtc.MediaStreamTrack? _processedTrack;
  web.MediaStreamTrack? _outputTrack;
  web.AudioContext? _audioContext;
  web.MediaStreamAudioSourceNode? _sourceNode;
  web.AudioWorkletNode? _workletNode;
  web.MediaStreamAudioDestinationNode? _destinationNode;
  web.EventListener? _visibilityListener;
  bool _bypassed = false;
  bool _destroyed = false;

  @override
  String get name => 'rnnoise';

  @override
  rtc.MediaStreamTrack? get processedTrack => _processedTrack;

  @override
  Future<void> init(lk.AudioProcessorOptions options) async {
    _destroyed = false;
    _bypassed = false;
    _inputTrack = options.track;
    try {
      final inputTrack = options.track;
      if (inputTrack is! MediaStreamTrackWeb) {
        throw StateError('Web microphone track is unavailable');
      }

      final baseUri = Uri.parse(web.document.baseURI);
      final context = web.AudioContext(
        web.AudioContextOptions(
          latencyHint: 'interactive'.toJS,
          sampleRate: 48000,
        ),
      );
      _audioContext = context;
      await context.resume().toDart.timeout(const Duration(seconds: 3));
      if (context.state != 'running') {
        throw StateError('AudioContext is ${context.state}');
      }

      final workletUri = baseUri.resolve(_workletPath);
      final wasmUri = baseUri.resolve(_wasmPath);
      final wasmResponse = await web.window
          .fetch(wasmUri.toString().toJS)
          .toDart
          .timeout(const Duration(seconds: 5));
      if (!wasmResponse.ok) {
        throw StateError('RNNoise WASM returned HTTP ${wasmResponse.status}');
      }
      final wasmBinary = await wasmResponse.arrayBuffer().toDart.timeout(
        const Duration(seconds: 5),
      );
      await context.audioWorklet
          .addModule(workletUri.toString())
          .toDart
          .timeout(const Duration(seconds: 5));

      final source = context.createMediaStreamSource(
        web.MediaStream(<web.MediaStreamTrack>[inputTrack.jsTrack].toJS),
      );
      final destination = context.createMediaStreamDestination();
      final worklet = web.AudioWorkletNode(
        context,
        _processorName,
        web.AudioWorkletNodeOptions(
          channelCount: 1,
          numberOfInputs: 1,
          numberOfOutputs: 1,
          outputChannelCount: <JSNumber>[1.toJS].toJS,
          processorOptions: _RnnoiseProcessorOptions(
            maxChannels: 1,
            wasmBinary: wasmBinary,
          ),
        ),
      );
      _sourceNode = source;
      _workletNode = worklet;
      _destinationNode = destination;
      source.connect(worklet);
      worklet.connect(destination);

      final outputTracks = destination.stream.getAudioTracks().toDart;
      if (outputTracks.isEmpty) {
        throw StateError('RNNoise did not produce an audio track');
      }
      _outputTrack = outputTracks.first;
      _processedTrack = MediaStreamTrackWeb(outputTracks.first);

      worklet.onprocessorerror = ((web.Event _) {
        unawaited(_bypassRnnoise('AudioWorklet processor error'));
      }).toJS;
      _visibilityListener = ((web.Event _) {
        if (web.document.visibilityState == 'visible') {
          unawaited(_resumeContext());
        }
      }).toJS;
      web.document.addEventListener('visibilitychange', _visibilityListener);

      await inputTrack.applyConstraints({'noiseSuppression': false});
      try {
        await inputTrack.applyConstraints({'voiceIsolation': false});
      } catch (_) {
        // voiceIsolation is still experimental and unsupported in many browsers.
      }
      ClientLog.write(
        'voice.rnnoise',
        'active sample_rate=${context.sampleRate.toStringAsFixed(0)} '
            'input_settings=${inputTrack.getSettings()}',
      );
    } catch (error, stackTrace) {
      ClientLog.error('voice.rnnoise', error, stackTrace);
      await _restoreBrowserNoiseSuppression();
      await _tearDown();
      ClientLog.write('voice.rnnoise', 'fallback=browser_noise_suppression');
    }
  }

  Future<void> _resumeContext() async {
    final context = _audioContext;
    if (_destroyed || context == null || context.state == 'running') return;
    try {
      await context.resume().toDart.timeout(const Duration(seconds: 3));
      if (context.state != 'running') {
        await _bypassRnnoise('AudioContext resume ended in ${context.state}');
      }
    } catch (error) {
      await _bypassRnnoise('AudioContext resume failed: $error');
    }
  }

  Future<void> _bypassRnnoise(String reason) async {
    if (_destroyed || _bypassed) return;
    final source = _sourceNode;
    final worklet = _workletNode;
    final destination = _destinationNode;
    if (source == null || worklet == null || destination == null) return;
    _bypassed = true;
    try {
      source.disconnect();
      worklet.disconnect();
      source.connect(destination);
      await _restoreBrowserNoiseSuppression();
      ClientLog.write(
        'voice.rnnoise',
        'fallback=browser_noise_suppression reason=$reason',
      );
    } catch (error, stackTrace) {
      ClientLog.error('voice.rnnoise.fallback', error, stackTrace);
    }
  }

  Future<void> _restoreBrowserNoiseSuppression() async {
    try {
      await _inputTrack?.applyConstraints({'noiseSuppression': true});
    } catch (_) {}
    try {
      await _inputTrack?.applyConstraints({'voiceIsolation': true});
    } catch (_) {}
  }

  Future<void> _tearDown() async {
    final visibilityListener = _visibilityListener;
    if (visibilityListener != null) {
      web.document.removeEventListener('visibilitychange', visibilityListener);
    }
    _visibilityListener = null;
    try {
      _sourceNode?.disconnect();
    } catch (_) {}
    try {
      _workletNode?.disconnect();
      _workletNode?.port.postMessage('destroy'.toJS);
    } catch (_) {}
    try {
      _outputTrack?.stop();
    } catch (_) {}
    try {
      await _audioContext?.close().toDart;
    } catch (_) {}
    _sourceNode = null;
    _workletNode = null;
    _destinationNode = null;
    _outputTrack = null;
    _audioContext = null;
    _processedTrack = null;
  }

  @override
  Future<void> restart(lk.AudioProcessorOptions options) async {
    await destroy();
    await init(options);
  }

  @override
  Future<void> destroy() async {
    _destroyed = true;
    await _restoreBrowserNoiseSuppression();
    await _tearDown();
    _inputTrack = null;
  }

  @override
  Future<void> onPublish(lk.Room room) async {}

  @override
  Future<void> onUnpublish() async {}
}
