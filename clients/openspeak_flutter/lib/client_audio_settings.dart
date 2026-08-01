import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, PhysicalKeyboardKey;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'audio_device_monitor.dart';
import 'microphone_activation.dart';
import 'os_settings_shell.dart';
import 'os_theme.dart';
import 'voice_session_controller.dart';

class OsClientAudioSettingsPane extends StatefulWidget {
  const OsClientAudioSettingsPane({
    super.key,
    required this.deviceMonitor,
    required this.initialInputDeviceId,
    required this.initialOutputDeviceId,
    required this.initialActivationMode,
    required this.initialThreshold,
    required this.initialPushToTalkHotkey,
    required this.initialSoundEffectVolume,
    required this.microphoneInputLevel,
    required this.onSave,
    required this.onSoundEffectPreview,
    this.captureCoordinator,
    this.devicesOnly = false,
  });

  final AudioDeviceMonitor deviceMonitor;
  final String? initialInputDeviceId;
  final String? initialOutputDeviceId;
  final MicrophoneActivationMode initialActivationMode;
  final double initialThreshold;
  final MicrophoneHotkeyBinding? initialPushToTalkHotkey;
  final double initialSoundEffectVolume;
  final ValueListenable<double> microphoneInputLevel;
  final VoiceSessionController? captureCoordinator;
  final bool devicesOnly;
  final void Function(
    String? inputDeviceId,
    String? outputDeviceId,
    MicrophoneActivationMode activationMode,
    double threshold,
    MicrophoneHotkeyBinding? pushToTalkHotkey,
    double soundEffectVolume,
  )
  onSave;
  final ValueChanged<double> onSoundEffectPreview;

  @override
  State<OsClientAudioSettingsPane> createState() =>
      _OsClientAudioSettingsPaneState();
}

class _OsClientAudioSettingsPaneState extends State<OsClientAudioSettingsPane> {
  String inputValue = '';
  String outputValue = '';
  late MicrophoneActivationMode activationMode;
  late double threshold;
  late double soundEffectVolume;
  MicrophoneHotkeyBinding? pushToTalkHotkey;
  bool recordingHotkey = false;
  bool saving = false;
  final hotkeyFocusNode = FocusNode(debugLabel: 'push-to-talk-recorder');
  late final MicrophoneInputLevelPreview microphoneLevelPreview;

  @override
  void initState() {
    super.initState();
    inputValue = widget.initialInputDeviceId ?? '';
    outputValue = widget.initialOutputDeviceId ?? '';
    activationMode = widget.initialActivationMode;
    threshold = widget.initialThreshold;
    soundEffectVolume = widget.initialSoundEffectVolume
        .clamp(0.0, 1.0)
        .toDouble();
    pushToTalkHotkey = widget.initialPushToTalkHotkey;
    microphoneLevelPreview = MicrophoneInputLevelPreview(
      fallbackLevel: widget.microphoneInputLevel,
    );
    widget.deviceMonitor.addListener(_onDevicesChanged);
    widget.captureCoordinator?.registerMicrophonePreviewReleaseHandler(
      this,
      _releaseMicrophonePreview,
    );
    if (!widget.devicesOnly &&
        activationMode == MicrophoneActivationMode.voiceThreshold) {
      unawaited(_startMicrophonePreview());
    }
  }

  @override
  void didUpdateWidget(OsClientAudioSettingsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceMonitor == widget.deviceMonitor) return;
    oldWidget.deviceMonitor.removeListener(_onDevicesChanged);
    widget.deviceMonitor.addListener(_onDevicesChanged);
    _dropUnavailableSelections();
  }

  @override
  void dispose() {
    widget.deviceMonitor.removeListener(_onDevicesChanged);
    widget.captureCoordinator?.unregisterMicrophonePreviewReleaseHandler(this);
    hotkeyFocusNode.dispose();
    microphoneLevelPreview.dispose();
    super.dispose();
  }

  Future<void> _startMicrophonePreview() async {
    if (widget.captureCoordinator?.needsVoiceMicrophoneCapture == true) {
      await microphoneLevelPreview.stop();
      return;
    }
    await microphoneLevelPreview.start(
      deviceId: inputValue.isEmpty ? null : inputValue,
    );
  }

  Future<void> _releaseMicrophonePreview() => microphoneLevelPreview.stop();

  Future<void> _saveSettings() async {
    if (saving) return;
    setState(() => saving = true);
    await _releaseMicrophonePreview();
    if (!mounted) return;
    widget.onSave(
      inputValue.isEmpty ? null : inputValue,
      outputValue.isEmpty ? null : outputValue,
      activationMode,
      threshold,
      pushToTalkHotkey,
      soundEffectVolume,
    );
  }

  void _setActivationMode(MicrophoneActivationMode mode) {
    setState(() => activationMode = mode);
    if (mode == MicrophoneActivationMode.voiceThreshold) {
      unawaited(_startMicrophonePreview());
    } else {
      unawaited(microphoneLevelPreview.stop());
    }
  }

  KeyEventResult _recordHotkey(FocusNode node, KeyEvent event) {
    if (!recordingHotkey) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.physicalKey == PhysicalKeyboardKey.escape) {
      setState(() => recordingHotkey = false);
      return KeyEventResult.handled;
    }
    if (event.physicalKey == PhysicalKeyboardKey.backspace ||
        event.physicalKey == PhysicalKeyboardKey.delete) {
      setState(() {
        pushToTalkHotkey = null;
        recordingHotkey = false;
      });
      return KeyEventResult.handled;
    }
    if (isModifierPhysicalKey(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    final modifiers = currentHotkeyModifiers();
    setState(() {
      pushToTalkHotkey = MicrophoneHotkeyBinding(
        usbHidUsage: event.physicalKey.usbHidUsage,
        modifiers: modifiers,
        label: hotkeyLabel(event.physicalKey, modifiers),
      );
      recordingHotkey = false;
    });
    return KeyEventResult.handled;
  }

  void _onDevicesChanged() {
    if (!mounted) return;
    setState(_dropUnavailableSelections);
  }

  void _dropUnavailableSelections() {
    if (!widget.deviceMonitor.lastRefreshSucceeded) return;
    final next = audioDeviceSelectionAfterRefresh(
      inputDeviceId: inputValue.isEmpty ? null : inputValue,
      outputDeviceId: outputValue.isEmpty ? null : outputValue,
      devices: widget.deviceMonitor.devices.where(
        (device) => !isWebRtcVirtualDefaultAudioDevice(device),
      ),
    );
    inputValue = next.inputDeviceId ?? '';
    outputValue = next.outputDeviceId ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final monitor = widget.deviceMonitor;
    if (!monitor.hasLoaded && monitor.error == null) {
      return const OsSettingsPage(
        icon: Icons.headphones_rounded,
        title: '音频设备',
        subtitle: '选择通话使用的输入和输出设备。',
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(36),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }
    if (!monitor.hasLoaded && monitor.error != null) {
      return OsSettingsPage(
        icon: Icons.headphones_rounded,
        title: '音频设备',
        subtitle: '选择通话使用的输入和输出设备。',
        child: OsSettingsTile(
          icon: Icons.error_outline_rounded,
          title: '无法读取音频设备',
          subtitle: '${monitor.error}',
          enabled: false,
        ),
      );
    }
    final devices = monitor.devices;
    final inputs = selectableAudioDevices(devices, 'audioinput');
    final outputs = selectableAudioDevices(devices, 'audiooutput');
    final currentDefaultInput = webRtcDefaultAudioDeviceName(
      devices,
      'audioinput',
    );
    final defaultInputLabel = systemDefaultAudioDeviceLabel(
      devices,
      'audioinput',
      '系统默认麦克风',
    );
    final defaultOutputLabel = systemDefaultAudioDeviceLabel(
      devices,
      'audiooutput',
      '系统默认扬声器',
    );
    return OsSettingsPage(
      icon: Icons.headphones_rounded,
      title: '音频设备',
      subtitle: '选择通话使用的输入和输出设备。',
      footer: Align(
        alignment: Alignment.centerRight,
        child: OsPrimaryButton(
          label: saving ? '正在保存…' : '保存设置',
          icon: Icons.check_rounded,
          onPressed: () {
            if (!saving) unawaited(_saveSettings());
          },
        ),
      ),
      child: Column(
        children: [
          OsFormCard(
            icon: Icons.mic_none_rounded,
            title: '麦克风',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AudioDeviceDropdown(
                  label: '输入设备',
                  value: inputValue,
                  devices: inputs,
                  emptyLabel: inputs.isEmpty && currentDefaultInput == null
                      ? '未发现麦克风'
                      : defaultInputLabel,
                  onChanged: (value) {
                    setState(() => inputValue = value ?? '');
                    if (!widget.devicesOnly &&
                        activationMode ==
                            MicrophoneActivationMode.voiceThreshold) {
                      unawaited(_startMicrophonePreview());
                    }
                  },
                ),
                if (!widget.devicesOnly &&
                    (inputs.isNotEmpty || currentDefaultInput != null)) ...[
                  const SizedBox(height: 12),
                  MicrophoneActivationCard(
                    mode: activationMode,
                    threshold: threshold,
                    pushToTalkHotkey: pushToTalkHotkey,
                    microphoneInputLevel: microphoneLevelPreview,
                    recordingHotkey: recordingHotkey,
                    hotkeyFocusNode: hotkeyFocusNode,
                    onHotkeyEvent: _recordHotkey,
                    onModeChanged: _setActivationMode,
                    onThresholdChanged: (value) =>
                        setState(() => threshold = value),
                    onStartHotkeyRecording: () {
                      setState(() => recordingHotkey = true);
                      hotkeyFocusNode.requestFocus();
                    },
                    onClearHotkey: () => setState(() {
                      pushToTalkHotkey = null;
                      recordingHotkey = false;
                    }),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          OsFormCard(
            icon: Icons.volume_up_outlined,
            title: '扬声器',
            child: AudioDeviceDropdown(
              label: '输出设备',
              value: outputValue,
              devices: outputs,
              emptyLabel: defaultOutputLabel,
              onChanged: (value) {
                setState(() => outputValue = value ?? '');
              },
            ),
          ),
          if (!widget.devicesOnly) ...[
            const SizedBox(height: 12),
            OsFormCard(
              icon: Icons.music_note_rounded,
              title: '音效',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: OsFieldLabel('音效音量')),
                      Text(
                        '${(soundEffectVolume * 100).round()}%',
                        key: const ValueKey('sound-effect-volume-percent'),
                        style: const TextStyle(
                          color: OsColors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          fontFeatures: [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('sound-effect-volume-slider'),
                    value: soundEffectVolume,
                    divisions: 100,
                    onChanged: (value) =>
                        setState(() => soundEffectVolume = value),
                    onChangeEnd: widget.onSoundEffectPreview,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class MicrophoneActivationCard extends StatelessWidget {
  const MicrophoneActivationCard({
    super.key,
    required this.mode,
    required this.threshold,
    required this.pushToTalkHotkey,
    required this.microphoneInputLevel,
    required this.recordingHotkey,
    required this.hotkeyFocusNode,
    required this.onHotkeyEvent,
    required this.onModeChanged,
    required this.onThresholdChanged,
    required this.onStartHotkeyRecording,
    required this.onClearHotkey,
  });

  final MicrophoneActivationMode mode;
  final double threshold;
  final MicrophoneHotkeyBinding? pushToTalkHotkey;
  final ValueListenable<double> microphoneInputLevel;
  final bool recordingHotkey;
  final FocusNode hotkeyFocusNode;
  final FocusOnKeyEventCallback onHotkeyEvent;
  final ValueChanged<MicrophoneActivationMode> onModeChanged;
  final ValueChanged<double> onThresholdChanged;
  final VoidCallback onStartHotkeyRecording;
  final VoidCallback onClearHotkey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: OsColors.content,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: OsColors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OsFieldLabel('麦克风激活方式'),
          const SizedBox(height: 8),
          if (!kIsWeb) ...[
            MicrophoneActivationOption(
              selected: mode == MicrophoneActivationMode.pushToTalk,
              title: '按键通话',
              subtitle: '按住指定快捷键时传输声音',
              onTap: () => onModeChanged(MicrophoneActivationMode.pushToTalk),
              expanded: mode == MicrophoneActivationMode.pushToTalk
                  ? Focus(
                      focusNode: hotkeyFocusNode,
                      onKeyEvent: onHotkeyEvent,
                      child: PushToTalkHotkeyField(
                        binding: pushToTalkHotkey,
                        recording: recordingHotkey,
                        onRecord: onStartHotkeyRecording,
                        onClear: onClearHotkey,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 7),
          ],
          MicrophoneActivationOption(
            selected: mode == MicrophoneActivationMode.continuous,
            title: '自动语音',
            subtitle: '检测到声音时自动传输，无需按键',
            onTap: () => onModeChanged(MicrophoneActivationMode.continuous),
            expanded: mode == MicrophoneActivationMode.continuous
                ? const ActivationHint(text: '绿圈亮起且房间存在其他参与者时才会上传音频。')
                : null,
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 7),
            MicrophoneActivationOption(
              selected: mode == MicrophoneActivationMode.voiceThreshold,
              title: '语音阈值',
              subtitle: '输入音量超过阈值时自动传输',
              onTap: () =>
                  onModeChanged(MicrophoneActivationMode.voiceThreshold),
              expanded: mode == MicrophoneActivationMode.voiceThreshold
                  ? MicrophoneThresholdMeter(
                      level: microphoneInputLevel,
                      threshold: threshold,
                      onChanged: onThresholdChanged,
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class PushToTalkHotkeyField extends StatelessWidget {
  const PushToTalkHotkeyField({
    super.key,
    required this.binding,
    required this.recording,
    required this.onRecord,
    required this.onClear,
  });

  final MicrophoneHotkeyBinding? binding;
  final bool recording;
  final VoidCallback onRecord;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OsFieldLabel('系统级快捷键'),
        const SizedBox(height: 7),
        Row(
          children: [
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: InkWell(
                  onTap: onRecord,
                  borderRadius: BorderRadius.circular(9),
                  child: Container(
                    height: 42,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(
                      color: OsColors.sidebar,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: recording
                            ? OsColors.blurple
                            : OsColors.panelBorder,
                      ),
                    ),
                    child: Text(
                      recording
                          ? '请按下快捷键…'
                          : binding == null
                          ? '快捷键：未设置'
                          : hotkeyBindingLabel(binding!),
                      style: TextStyle(
                        color: recording || binding != null
                            ? OsColors.text
                            : OsColors.dim,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (binding != null) ...[
              const SizedBox(width: 7),
              IconButton(
                tooltip: '清除快捷键',
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '点击后录制下一组按键；Esc 取消，Delete 或 Backspace 清除。',
          style: TextStyle(color: OsColors.dim, fontSize: 10),
        ),
      ],
    );
  }
}

class MicrophoneThresholdMeter extends StatelessWidget {
  const MicrophoneThresholdMeter({
    super.key,
    required this.level,
    required this.threshold,
    required this.onChanged,
  });

  final ValueListenable<double> level;
  final double threshold;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const OsFieldLabel('输入音量与传输阈值'),
            Text(
              microphoneThresholdLabel(threshold),
              style: const TextStyle(
                color: OsColors.blurple,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<double>(
          valueListenable: level,
          builder: (context, inputLevel, _) => SizedBox(
            height: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    key: const ValueKey('microphone-current-level'),
                    value: inputLevel.clamp(0.0, 1.0).toDouble(),
                    minHeight: 8,
                    color: inputLevel >= threshold
                        ? OsColors.green
                        : OsColors.blurple,
                    backgroundColor: OsColors.sidebar,
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    trackHeight: 0,
                    thumbColor: OsColors.text,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayColor: const Color(0x335865F2),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey('microphone-threshold-slider'),
                    value: threshold.clamp(0.0, 1.0).toDouble(),
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          '点击或拖动音量条设置阈值；只有输入音量越过标记时才传输。',
          style: TextStyle(color: OsColors.dim, fontSize: 10),
        ),
      ],
    );
  }
}

class AudioDeviceDropdown extends StatelessWidget {
  const AudioDeviceDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.devices,
    required this.emptyLabel,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<rtc.MediaDeviceInfo> devices;
  final String emptyLabel;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = <({String label, String value})>[
      (value: '', label: emptyLabel),
      ...devices.map(
        (device) => (
          value: device.deviceId,
          label: device.label.trim().isEmpty ? '未命名设备' : device.label,
        ),
      ),
    ];
    final selection = options.any((option) => option.value == value)
        ? value
        : '';
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: OsColors.panelBorder),
    );
    return DropdownMenu<String>(
      key: ValueKey('audio-device-dropdown-$label'),
      initialSelection: selection,
      expandedInsets: EdgeInsets.zero,
      selectOnly: true,
      requestFocusOnTap: true,
      enableSearch: false,
      label: Text(label),
      textStyle: const TextStyle(
        color: OsColors.text,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
      trailingIcon: const Icon(
        Icons.keyboard_arrow_down_rounded,
        color: OsColors.muted,
        size: 22,
      ),
      selectedTrailingIcon: const Icon(
        Icons.keyboard_arrow_up_rounded,
        color: OsColors.muted,
        size: 22,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: OsColors.field,
        constraints: const BoxConstraints.tightFor(height: 64),
        contentPadding: const EdgeInsets.fromLTRB(15, 10, 8, 8),
        labelStyle: const TextStyle(
          color: OsColors.dim,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        floatingLabelStyle: const TextStyle(
          color: OsColors.dim,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: const BorderSide(color: OsColors.blurple),
        ),
      ),
      menuStyle: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(OsColors.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(18),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: OsColors.panelBorder),
          ),
        ),
      ),
      dropdownMenuEntries: [
        for (final option in options)
          DropdownMenuEntry<String>(
            value: option.value,
            label: option.label,
            labelWidget: Text(
              option.label,
              key: ValueKey('audio-device-option-${option.value}'),
              overflow: TextOverflow.ellipsis,
            ),
            trailingIcon: option.value == selection
                ? const Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: OsColors.blurple,
                  )
                : null,
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size.fromHeight(44)),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 12),
              ),
              foregroundColor: WidgetStatePropertyAll(
                option.value == selection ? OsColors.text : OsColors.muted,
              ),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (option.value == selection) return OsColors.blurpleSoft;
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return OsColors.rowHover;
                }
                return Colors.transparent;
              }),
              textStyle: WidgetStatePropertyAll(
                TextStyle(
                  fontSize: 14,
                  fontWeight: option.value == selection
                      ? FontWeight.w700
                      : FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
      onSelected: onChanged,
    );
  }
}
