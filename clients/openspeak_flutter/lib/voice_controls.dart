import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'client_log.dart';
import 'os_avatar.dart';
import 'os_settings_shell.dart';
import 'os_theme.dart';
import 'screen_share.dart';
import 'smooth_scroll.dart';
import 'voice_session_controller.dart';

enum AudioVolumePopoverKind { input, output }

class CurrentUserBar extends StatefulWidget {
  const CurrentUserBar({
    super.key,
    required this.connected,
    required this.displayName,
    this.avatarFile,
    this.avatarRevision = 0,
    this.avatarUri,
    this.avatarToken,
    required this.online,
    required this.muted,
    this.canSpeak = true,
    this.canShareScreen = false,
    this.screenSharing = false,
    this.screenShareBusy = false,
    this.screenShareUnavailableReason,
    required this.listenOff,
    this.noiseSuppressionEnabled = true,
    required this.inputVolume,
    required this.outputVolume,
    required this.onMute,
    required this.onListenOff,
    this.onNoiseSuppressionToggle,
    required this.onInputVolumeChanged,
    required this.onOutputVolumeChanged,
    this.onScreenShare,
    required this.onSettings,
    this.upstreamPacketLoss,
    this.downstreamPacketLoss,
    this.latencyMs,
    this.latencyJitterMs,
  });

  final bool connected;
  final String displayName;
  final File? avatarFile;
  final int avatarRevision;
  final Uri? avatarUri;
  final String? avatarToken;
  final bool online;
  final bool muted;
  final bool canSpeak;
  final bool canShareScreen;
  final bool screenSharing;
  final bool screenShareBusy;
  final String? screenShareUnavailableReason;
  final bool listenOff;
  final bool noiseSuppressionEnabled;
  final double inputVolume;
  final double outputVolume;
  final double? upstreamPacketLoss;
  final double? downstreamPacketLoss;
  final double? latencyMs;
  final double? latencyJitterMs;
  final VoidCallback onMute;
  final VoidCallback onListenOff;
  final VoidCallback? onNoiseSuppressionToggle;
  final ValueChanged<double> onInputVolumeChanged;
  final ValueChanged<double> onOutputVolumeChanged;
  final VoidCallback? onScreenShare;
  final VoidCallback onSettings;

  @override
  State<CurrentUserBar> createState() => _CurrentUserBarState();
}

class _CurrentUserBarState extends State<CurrentUserBar> {
  final LayerLink _networkStatsLink = LayerLink();
  final LayerLink _inputVolumeLink = LayerLink();
  final LayerLink _outputVolumeLink = LayerLink();
  OverlayEntry? _volumeOverlay;
  OverlayEntry? _networkStatsOverlay;
  AudioVolumePopoverKind? _openVolumeKind;
  Timer? _volumeHideTimer;

  @override
  void didUpdateWidget(CurrentUserBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.connected) {
      _hideVolumePopover();
      _hideNetworkStats();
    } else if (_openVolumeKind != null &&
        (oldWidget.inputVolume != widget.inputVolume ||
            oldWidget.outputVolume != widget.outputVolume ||
            oldWidget.muted != widget.muted ||
            oldWidget.listenOff != widget.listenOff)) {
      final overlay = _volumeOverlay;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_volumeOverlay, overlay)) {
          overlay?.markNeedsBuild();
        }
      });
    }
    if (oldWidget.canSpeak &&
        !widget.canSpeak &&
        _openVolumeKind == AudioVolumePopoverKind.input) {
      _removeVolumePopover(notify: false);
    }
    if (oldWidget.upstreamPacketLoss != widget.upstreamPacketLoss ||
        oldWidget.downstreamPacketLoss != widget.downstreamPacketLoss ||
        oldWidget.latencyMs != widget.latencyMs ||
        oldWidget.latencyJitterMs != widget.latencyJitterMs) {
      _networkStatsOverlay?.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _volumeHideTimer?.cancel();
    _removeVolumePopover(notify: false);
    _removeNetworkStats(notify: false);
    super.dispose();
  }

  void _showVolumePopover(AudioVolumePopoverKind kind) {
    if (!widget.connected ||
        (kind == AudioVolumePopoverKind.input && !widget.canSpeak)) {
      return;
    }
    _cancelVolumePopoverHide();
    if (_openVolumeKind == kind && _volumeOverlay != null) return;
    _hideNetworkStats();
    _hideVolumePopover();
    _openVolumeKind = kind;
    _volumeOverlay = OverlayEntry(
      builder: (context) {
        final activeKind = _openVolumeKind;
        if (activeKind == null) return const SizedBox.shrink();
        final link = activeKind == AudioVolumePopoverKind.input
            ? _inputVolumeLink
            : _outputVolumeLink;
        final value = activeKind == AudioVolumePopoverKind.input
            ? (widget.muted ? 0.0 : widget.inputVolume)
            : (widget.listenOff ? 0.0 : widget.outputVolume);
        final label = activeKind == AudioVolumePopoverKind.input
            ? '麦克风音量'
            : '扬声器音量';
        return CompositedTransformFollower(
          link: link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -8),
          child: UnconstrainedBox(
            alignment: Alignment.bottomCenter,
            child: MouseRegion(
              onEnter: (_) => _cancelVolumePopoverHide(),
              onExit: (_) => _scheduleVolumePopoverHide(),
              child: Material(
                color: Colors.transparent,
                child: AudioVolumePopover(
                  label: label,
                  value: value,
                  onChanged: activeKind == AudioVolumePopoverKind.input
                      ? widget.onInputVolumeChanged
                      : widget.onOutputVolumeChanged,
                ),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_volumeOverlay!);
    setState(() {});
  }

  void _hideVolumePopover() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = null;
    _removeVolumePopover();
  }

  void _scheduleVolumePopoverHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(milliseconds: 300), () {
      _volumeHideTimer = null;
      if (mounted) _hideVolumePopover();
    });
  }

  void _cancelVolumePopoverHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = null;
  }

  void _removeVolumePopover({bool notify = true}) {
    _volumeOverlay?.remove();
    _volumeOverlay = null;
    _openVolumeKind = null;
    if (notify && mounted) setState(() {});
  }

  void _toggleNetworkStats() {
    if (_networkStatsOverlay != null) {
      _hideNetworkStats();
      return;
    }
    if (!widget.connected) return;
    _hideVolumePopover();
    _networkStatsOverlay = OverlayEntry(
      builder: (context) => CompositedTransformFollower(
        link: _networkStatsLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(-5, -8),
        child: UnconstrainedBox(
          alignment: Alignment.bottomLeft,
          child: TapRegion(
            onTapOutside: (_) => _hideNetworkStats(),
            child: Material(
              color: Colors.transparent,
              child: NetworkStatsCard(
                upstreamPacketLoss: widget.upstreamPacketLoss,
                downstreamPacketLoss: widget.downstreamPacketLoss,
                latencyMs: widget.latencyMs,
                latencyJitterMs: widget.latencyJitterMs,
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_networkStatsOverlay!);
    setState(() {});
  }

  void _hideNetworkStats() {
    _removeNetworkStats();
  }

  void _removeNetworkStats({bool notify = true}) {
    _networkStatsOverlay?.remove();
    _networkStatsOverlay = null;
    if (notify && mounted) setState(() {});
  }

  Widget _volumeIconButton({
    required AudioVolumePopoverKind kind,
    required LayerLink link,
    required String tooltip,
    required IconData icon,
    required bool active,
    required VoidCallback? onPressed,
  }) {
    return CompositedTransformTarget(
      link: link,
      child: MouseRegion(
        onEnter: (_) => _showVolumePopover(kind),
        onExit: (_) => _scheduleVolumePopoverHide(),
        child: StatusBarIconButton(
          tooltip: tooltip,
          icon: icon,
          active: active,
          selected: _openVolumeKind == kind,
          onPressed: onPressed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardTop = widget.connected ? 45.0 : 79.0;
    final cardHeight = widget.connected ? 77.0 : 43.0;
    const userBarWidth = 239.0;
    const cardLeft = 6.0;
    const cardWidth = 227.0;
    const statusIconTop = 51.0;
    const statusIconSlot = 28.0;
    const networkIconSize = 20.0;
    const audioIconSize = 18.0;
    const audioIconGroupWidth = statusIconSlot * (kIsWeb ? 2 : 4);
    const settingsIconLeft = 201.0;
    const speakerVisualRight =
        settingsIconLeft + (statusIconSlot + audioIconSize) / 2;
    const mirroredStatusVisualLeft = userBarWidth - speakerVisualRight;
    const statusIconGroupLeft =
        mirroredStatusVisualLeft - (statusIconSlot - networkIconSize) / 2;
    return SizedBox(
      width: userBarWidth,
      height: 132,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: cardLeft,
            top: cardTop,
            width: cardWidth,
            height: cardHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: OsColors.sidebarBottom,
                borderRadius: BorderRadius.circular(9),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 5,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
            ),
          ),
          if (widget.connected) ...[
            Positioned(
              left: statusIconGroupLeft,
              top: statusIconTop,
              child: Row(
                children: [
                  CompositedTransformTarget(
                    link: _networkStatsLink,
                    child: NetworkQualityButton(
                      latencyMs: widget.latencyMs,
                      latencyJitterMs: widget.latencyJitterMs,
                      upstreamPacketLoss: widget.upstreamPacketLoss,
                      downstreamPacketLoss: widget.downstreamPacketLoss,
                      selected: _networkStatsOverlay != null,
                      onPressed: _toggleNetworkStats,
                    ),
                  ),
                  SizedBox(
                    width: statusIconSlot,
                    height: statusIconSlot,
                    child: StatusBarIconButton(
                      tooltip: widget.screenSharing
                          ? '停止分享屏幕'
                          : widget.screenShareBusy
                          ? '正在切换屏幕共享'
                          : widget.screenShareUnavailableReason ??
                                (widget.canShareScreen
                                    ? '分享屏幕'
                                    : '请先进入语音频道或检查屏幕共享权限'),
                      icon: widget.screenSharing
                          ? Icons.stop_screen_share_rounded
                          : Icons.screen_share,
                      iconSize: 20,
                      active: widget.screenSharing || widget.canShareScreen,
                      activeColor: widget.screenSharing
                          ? OsColors.green
                          : Colors.white,
                      onPressed:
                          !widget.screenShareBusy &&
                              (widget.screenSharing || widget.canShareScreen)
                          ? widget.onScreenShare
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: settingsIconLeft + statusIconSlot - audioIconGroupWidth,
              top: statusIconTop,
              child: Row(
                children: [
                  if (!kIsWeb)
                    StatusBarIconButton(
                      key: const ValueKey('noise-suppression-toggle'),
                      tooltip: widget.noiseSuppressionEnabled ? '关闭降噪' : '开启降噪',
                      iconWidget: Opacity(
                        opacity: widget.noiseSuppressionEnabled ? 1 : 0.4,
                        child: Image.asset(
                          'assets/images/noise_suppression.png',
                          key: const ValueKey('noise-suppression-icon'),
                          width: 52,
                          height: 26,
                          fit: BoxFit.contain,
                        ),
                      ),
                      width: 56,
                      onPressed: widget.onNoiseSuppressionToggle,
                    ),
                  _volumeIconButton(
                    kind: AudioVolumePopoverKind.input,
                    link: _inputVolumeLink,
                    tooltip: !widget.canSpeak
                        ? '没有发送语音权限'
                        : widget.muted
                        ? '取消静音'
                        : '静音',
                    icon: !widget.canSpeak || widget.muted
                        ? Icons.mic_off
                        : Icons.mic,
                    active: widget.canSpeak && !widget.muted,
                    onPressed: widget.canSpeak ? widget.onMute : null,
                  ),
                  _volumeIconButton(
                    kind: AudioVolumePopoverKind.output,
                    link: _outputVolumeLink,
                    tooltip: widget.listenOff ? '开启收听' : '关闭收听',
                    icon: widget.listenOff ? Icons.volume_off : Icons.volume_up,
                    active: !widget.listenOff,
                    onPressed: widget.onListenOff,
                  ),
                ],
              ),
            ),
          ],
          Positioned(
            left: 14,
            top: 87,
            child: OsUserAvatar(
              displayName: widget.displayName,
              size: 29,
              avatarFile: widget.avatarFile,
              avatarRevision: widget.avatarRevision,
              avatarUri: widget.avatarUri,
              avatarToken: widget.avatarToken,
              backgroundColor: const Color(0xFFA55CD2),
            ),
          ),
          Positioned(
            left: 52,
            top: 87,
            width: 150,
            height: 29,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                key: const ValueKey('current-user-display-name'),
                widget.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: OsColors.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          Positioned(
            left: settingsIconLeft,
            top: 89,
            child: StatusBarIconButton(
              tooltip: '设置',
              icon: Icons.settings,
              onPressed: widget.onSettings,
            ),
          ),
        ],
      ),
    );
  }
}

class StatusBarIconButton extends StatelessWidget {
  const StatusBarIconButton({
    super.key,
    required this.tooltip,
    this.icon,
    this.iconWidget,
    required this.onPressed,
    this.active = false,
    this.selected = false,
    this.activeColor = Colors.white,
    this.width = 28,
    this.iconSize = 18,
  }) : assert(icon != null || iconWidget != null);

  final String tooltip;
  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback? onPressed;
  final bool active;
  final bool selected;
  final Color activeColor;
  final double width;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: selected ? OsColors.rowSelected : Colors.transparent,
          minimumSize: Size(width, 28),
          fixedSize: Size(width, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        constraints: BoxConstraints.tightFor(width: width, height: 28),
        mouseCursor: onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onPressed: onPressed,
        icon:
            iconWidget ??
            Icon(
              icon,
              size: iconSize,
              color: active ? activeColor : OsColors.dim,
            ),
      ),
    );
  }
}

class ScreenShareSourceDialog extends StatefulWidget {
  const ScreenShareSourceDialog({super.key});

  @override
  State<ScreenShareSourceDialog> createState() =>
      _ScreenShareSourceDialogState();
}

class _ScreenShareSourceDialogState extends State<ScreenShareSourceDialog> {
  static const sourceTypes = [rtc.SourceType.Screen, rtc.SourceType.Window];

  final sources = <String, rtc.DesktopCapturerSource>{};
  final subscriptions = <StreamSubscription<rtc.DesktopCapturerSource>>[];
  rtc.SourceType sourceType = rtc.SourceType.Screen;
  rtc.DesktopCapturerSource? selectedSource;
  Timer? refreshTimer;
  String? loadError;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    subscriptions
      ..add(rtc.desktopCapturer.onAdded.stream.listen(_upsertSource))
      ..add(rtc.desktopCapturer.onRemoved.stream.listen(_removeSource))
      ..add(rtc.desktopCapturer.onNameChanged.stream.listen(_upsertSource))
      ..add(
        rtc.desktopCapturer.onThumbnailChanged.stream.listen(_upsertSource),
      );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadSources());
    });
  }

  List<rtc.DesktopCapturerSource> get visibleSources {
    final visible = sources.values
        .where((source) => source.type == sourceType)
        .toList();
    visible.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return visible;
  }

  void _selectFirstVisible() {
    final visible = visibleSources;
    selectedSource = visible.isEmpty ? null : visible.first;
  }

  void _upsertSource(rtc.DesktopCapturerSource source) {
    if (!mounted) return;
    setState(() {
      sources[source.id] = source;
      if (selectedSource == null && source.type == sourceType) {
        selectedSource = source;
      }
    });
  }

  void _removeSource(rtc.DesktopCapturerSource source) {
    if (!mounted) return;
    setState(() {
      sources.remove(source.id);
      if (selectedSource?.id == source.id) _selectFirstVisible();
    });
  }

  Future<void> _loadSources() async {
    if (mounted) {
      setState(() {
        loading = true;
        loadError = null;
      });
    }
    try {
      final loaded = await rtc.desktopCapturer.getSources(
        types: sourceTypes,
        thumbnailSize: rtc.ThumbnailSize(480, 270),
      );
      if (!mounted) return;
      setState(() {
        sources
          ..clear()
          ..addEntries(loaded.map((source) => MapEntry(source.id, source)));
        if (selectedSource == null ||
            !sources.containsKey(selectedSource!.id) ||
            selectedSource!.type != sourceType) {
          _selectFirstVisible();
        }
        loading = false;
      });
      refreshTimer ??= Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_refreshSources()),
      );
    } catch (exception, stackTrace) {
      ClientLog.error('voice.screen.sources', exception, stackTrace);
      if (!mounted) return;
      setState(() {
        loading = false;
        loadError = '无法读取可分享的屏幕或窗口';
      });
    }
  }

  Future<void> _refreshSources() async {
    try {
      await rtc.desktopCapturer.updateSources(types: sourceTypes);
    } catch (exception, stackTrace) {
      ClientLog.error('voice.screen.sources.refresh', exception, stackTrace);
    }
  }

  void _selectType(rtc.SourceType value) {
    if (sourceType == value) return;
    setState(() {
      sourceType = value;
      _selectFirstVisible();
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = visibleSources;
    final sourceLabel = sourceType == rtc.SourceType.Screen ? '整个屏幕' : '窗口';
    return OsSettingsDialog(
      icon: Icons.screen_share_rounded,
      eyebrow: '屏幕共享',
      title: '选择要分享的内容',
      subtitle: '选择一个屏幕或应用窗口，确认后立即开始分享。',
      maxWidth: 900,
      leadingActions: [
        OsSecondaryButton(label: '取消', onPressed: () => Navigator.pop(context)),
      ],
      actions: [
        if (selectedSource != null)
          OsPrimaryButton(
            label: '开始分享',
            icon: Icons.screen_share_rounded,
            onPressed: () => Navigator.pop(context, selectedSource),
          ),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 190,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF222429),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: OsColors.panelBorder),
            ),
            child: SmoothListView(
              padding: EdgeInsets.zero,
              children: [
                const OsSettingsNavSection('分享来源'),
                OsSettingsNavEntry(
                  icon: Icons.desktop_windows_rounded,
                  label: '整个屏幕',
                  selected: sourceType == rtc.SourceType.Screen,
                  onTap: () => _selectType(rtc.SourceType.Screen),
                ),
                OsSettingsNavEntry(
                  icon: Icons.web_asset_rounded,
                  label: '窗口',
                  selected: sourceType == rtc.SourceType.Window,
                  onTap: () => _selectType(rtc.SourceType.Window),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: OsSettingsPage(
              icon: sourceType == rtc.SourceType.Screen
                  ? Icons.desktop_windows_rounded
                  : Icons.web_asset_rounded,
              title: sourceLabel,
              subtitle: loading ? '正在读取可分享内容…' : '找到 ${visible.length} 项',
              child: loading
                  ? const SizedBox(
                      height: 280,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : loadError != null
                  ? SizedBox(
                      height: 280,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: OsColors.danger,
                              size: 30,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              loadError!,
                              style: const TextStyle(color: OsColors.muted),
                            ),
                            const SizedBox(height: 8),
                            OsSecondaryButton(
                              label: '重新加载',
                              icon: Icons.refresh_rounded,
                              onPressed: () => unawaited(_loadSources()),
                            ),
                          ],
                        ),
                      ),
                    )
                  : visible.isEmpty
                  ? SizedBox(
                      height: 280,
                      child: Center(
                        child: Text(
                          sourceType == rtc.SourceType.Screen
                              ? '没有找到可分享的屏幕'
                              : '没有找到可分享的窗口',
                          style: const TextStyle(color: OsColors.dim),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const spacing = 12.0;
                        final columns = (constraints.maxWidth / 250)
                            .floor()
                            .clamp(1, 4);
                        final cardWidth =
                            (constraints.maxWidth - spacing * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: spacing,
                          runSpacing: spacing,
                          children: [
                            for (final source in visible)
                              SizedBox(
                                width: cardWidth,
                                height: math.max(150, cardWidth / 1.42),
                                child: _ScreenShareSourceTile(
                                  source: source,
                                  selected: selectedSource?.id == source.id,
                                  onTap: () =>
                                      setState(() => selectedSource = source),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScreenShareSourceTile extends StatelessWidget {
  const _ScreenShareSourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final rtc.DesktopCapturerSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnail = source.thumbnail;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: selected ? OsColors.blurpleSoft : OsColors.panelRaised,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? OsColors.blurple : OsColors.panelBorder,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: const Color(0xFF111216),
                  child: thumbnail?.isNotEmpty == true
                      ? Image.memory(
                          thumbnail!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.hide_image_outlined,
                            color: OsColors.dim,
                            size: 30,
                          ),
                        )
                      : const Icon(
                          Icons.desktop_windows_outlined,
                          color: OsColors.dim,
                          size: 34,
                        ),
                ),
              ),
              Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(
                      source.type == rtc.SourceType.Screen
                          ? Icons.desktop_windows_rounded
                          : Icons.web_asset_rounded,
                      size: 16,
                      color: selected ? OsColors.blurple : OsColors.dim,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? OsColors.text : OsColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (selected)
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 17,
                        color: OsColors.blurple,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ScreenShareViewerActions extends StatelessWidget {
  const ScreenShareViewerActions({
    super.key,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onMaximize,
  });

  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onMaximize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusBarIconButton(
          key: const ValueKey('screen-share-collapse'),
          tooltip: collapsed ? '展开' : '折叠',
          icon: collapsed
              ? Icons.keyboard_arrow_down_rounded
              : Icons.keyboard_arrow_up_rounded,
          active: true,
          onPressed: onToggleCollapsed,
        ),
        StatusBarIconButton(
          key: const ValueKey('screen-share-expand'),
          tooltip: '最大化窗口',
          icon: Icons.fullscreen_rounded,
          active: true,
          onPressed: onMaximize,
        ),
      ],
    );
  }
}

class ScreenShareHeader extends StatelessWidget {
  const ScreenShareHeader({
    super.key,
    required this.title,
    required this.actions,
  });

  final String title;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _screenShareHeaderHeight,
      padding: const EdgeInsets.only(left: 13, right: 8),
      color: OsColors.panelRaised,
      child: Row(
        children: [
          const Icon(
            Icons.screen_share_rounded,
            size: 18,
            color: OsColors.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: OsColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          actions,
        ],
      ),
    );
  }
}

const _screenShareHeaderHeight = 38.0;
const _screenShareStageTopInset = 14.0;
const screenShareStageHorizontalInset = 16.0;
const _screenShareStageBorderWidth = 1.0;

Widget screenShareOverlay({
  required Widget chat,
  required Widget stage,
  required double stageWidth,
  double? stageHeight,
}) => Stack(
  children: [
    Positioned.fill(child: chat),
    Positioned(
      top: 0,
      right: 0,
      width: stageWidth,
      height: stageHeight,
      child: stage,
    ),
  ],
);

double screenShareStagePanelWidth({
  required double maxWidth,
  required double maxHeight,
  required double aspectRatio,
}) {
  final availableWidth = math
      .max(0.0, maxWidth - screenShareStageHorizontalInset * 2)
      .toDouble();
  if (!aspectRatio.isFinite || aspectRatio <= 0) return availableWidth;
  final videoHeight = math
      .max(
        0.0,
        maxHeight -
            _screenShareStageTopInset -
            _screenShareHeaderHeight -
            _screenShareStageBorderWidth * 2,
      )
      .toDouble();
  return math
      .min(
        availableWidth,
        videoHeight * aspectRatio + _screenShareStageBorderWidth * 2,
      )
      .toDouble();
}

class ScreenShareStage extends StatelessWidget {
  const ScreenShareStage({
    super.key,
    required this.share,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onMaximize,
  });

  final VoiceScreenShare share;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onMaximize;

  @override
  Widget build(BuildContext context) {
    final name = share.displayName.trim().isEmpty
        ? share.userId
        : share.displayName;
    final panel = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111216),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: OsColors.panelBorder,
          width: _screenShareStageBorderWidth,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: collapsed ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenShareHeader(
            title: '$name 正在分享屏幕',
            actions: ScreenShareViewerActions(
              collapsed: collapsed,
              onToggleCollapsed: onToggleCollapsed,
              onMaximize: onMaximize,
            ),
          ),
          if (!collapsed)
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: lk.VideoTrackRenderer(
                  share.track,
                  fit: lk.VideoViewFit.contain,
                ),
              ),
            ),
        ],
      ),
    );
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          screenShareStageHorizontalInset,
          _screenShareStageTopInset,
          screenShareStageHorizontalInset,
          0,
        ),
        child: panel,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth = screenShareStagePanelWidth(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          aspectRatio: share.aspectRatio,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            screenShareStageHorizontalInset,
            _screenShareStageTopInset,
            screenShareStageHorizontalInset,
            0,
          ),
          child: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: panelWidth,
              height: math.max(
                0.0,
                constraints.maxHeight - _screenShareStageTopInset,
              ),
              child: panel,
            ),
          ),
        );
      },
    );
  }
}

class ScreenShareWindow extends StatelessWidget {
  const ScreenShareWindow({super.key, required this.controller});

  final VoiceSessionController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF111216),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: OsColors.panelBorder),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 36,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final share = controller.activeScreenShare;
                final name = share == null
                    ? ''
                    : share.displayName.trim().isEmpty
                    ? share.userId
                    : share.displayName;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ScreenShareHeader(
                      title: share == null ? '屏幕共享' : '$name 正在分享屏幕',
                      actions: StatusBarIconButton(
                        key: const ValueKey('screen-share-window-return'),
                        tooltip: '还原窗口',
                        icon: Icons.fullscreen_exit_rounded,
                        active: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    Expanded(
                      child: share == null
                          ? const Center(
                              child: Text(
                                '屏幕共享已结束',
                                style: TextStyle(
                                  color: OsColors.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : ColoredBox(
                              color: Colors.black,
                              child: lk.VideoTrackRenderer(
                                share.track,
                                fit: lk.VideoViewFit.contain,
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class NetworkQualityButton extends StatelessWidget {
  const NetworkQualityButton({
    super.key,
    required this.latencyMs,
    required this.latencyJitterMs,
    required this.upstreamPacketLoss,
    required this.downstreamPacketLoss,
    required this.selected,
    required this.onPressed,
  });

  final double? latencyMs;
  final double? latencyJitterMs;
  final double? upstreamPacketLoss;
  final double? downstreamPacketLoss;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final quality = networkQualityForStats(
      latencyMs: latencyMs,
      latencyJitterMs: latencyJitterMs,
      upstreamPacketLoss: upstreamPacketLoss,
      downstreamPacketLoss: downstreamPacketLoss,
    );
    final icon = switch (quality.bars) {
      1 => Icons.signal_cellular_alt_1_bar,
      2 => Icons.signal_cellular_alt_2_bar,
      _ => Icons.signal_cellular_alt,
    };
    return Tooltip(
      message: '网络状态',
      child: InkResponse(
        onTap: onPressed,
        mouseCursor: SystemMouseCursors.click,
        radius: 16,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: selected ? OsColors.rowSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: quality.bars == 0 ? OsColors.icon : quality.color,
          ),
        ),
      ),
    );
  }
}

class NetworkQuality {
  const NetworkQuality({required this.bars, required this.color});

  final int bars;
  final Color color;
}

NetworkQuality networkQualityForStats({
  required double? latencyMs,
  required double? latencyJitterMs,
  required double? upstreamPacketLoss,
  required double? downstreamPacketLoss,
}) {
  if (latencyMs == null) {
    return const NetworkQuality(bars: 0, color: OsColors.icon);
  }
  final jitter = latencyJitterMs ?? 0;
  final worstPacketLoss = math.max(
    upstreamPacketLoss ?? 0,
    downstreamPacketLoss ?? 0,
  );
  if (latencyMs > 200 || jitter > 30 || worstPacketLoss > 3) {
    return const NetworkQuality(bars: 1, color: OsColors.danger);
  }
  if (latencyMs > 100 || jitter > 10 || worstPacketLoss >= 1) {
    return const NetworkQuality(bars: 2, color: Color(0xFFF0A020));
  }
  return const NetworkQuality(bars: 3, color: OsColors.green);
}

class NetworkStatsCard extends StatelessWidget {
  const NetworkStatsCard({
    super.key,
    required this.upstreamPacketLoss,
    required this.downstreamPacketLoss,
    required this.latencyMs,
    required this.latencyJitterMs,
  });

  final double? upstreamPacketLoss;
  final double? downstreamPacketLoss;
  final double? latencyMs;
  final double? latencyJitterMs;

  String _loss(double? value) =>
      value == null ? '--' : '${value.toStringAsFixed(1)}%';

  String _latency(double? value, double? deviation) {
    if (value == null) return '--';
    if (deviation == null) return '${value.round()} ms';
    return '${value.round()} ms ± ${deviation.toStringAsFixed(1)} ms';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 227,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: OsColors.sidebarBottom,
        borderRadius: BorderRadius.circular(9),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 5,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row('上行丢包', _loss(upstreamPacketLoss)),
          const SizedBox(height: 6),
          _row('下行丢包', _loss(downstreamPacketLoss)),
          const SizedBox(height: 6),
          _row(
            '延迟',
            _latency(latencyMs, latencyJitterMs),
            compactPlusMinus: true,
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool compactPlusMinus = false}) {
    final plusMinusIndex = compactPlusMinus ? value.indexOf('±') : -1;
    final valueWidget = plusMinusIndex < 0
        ? Text(
            value,
            style: const TextStyle(
              color: OsColors.text,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          )
        : Text.rich(
            TextSpan(
              style: const TextStyle(
                color: OsColors.text,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
              children: [
                TextSpan(text: value.substring(0, plusMinusIndex)),
                const TextSpan(text: '±', style: TextStyle(fontSize: 9)),
                TextSpan(text: value.substring(plusMinusIndex + 1)),
              ],
            ),
          );
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: OsColors.muted, fontSize: 11),
          ),
        ),
        valueWidget,
      ],
    );
  }
}

class AudioVolumePopover extends StatelessWidget {
  const AudioVolumePopover({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final percent = (value.clamp(0.0, 1.0) * 100).round();
    return Semantics(
      label: '$label $percent%',
      slider: true,
      value: '$percent%',
      child: Container(
        width: 44,
        height: 116,
        decoration: BoxDecoration(
          color: const Color(0xFF2F3136),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xFF3A3D42)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 10,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: VerticalVolumeSlider(value: value, onChanged: onChanged),
      ),
    );
  }
}

class VerticalVolumeSlider extends StatefulWidget {
  const VerticalVolumeSlider({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<VerticalVolumeSlider> createState() => _VerticalVolumeSliderState();
}

class _VerticalVolumeSliderState extends State<VerticalVolumeSlider> {
  late double value = widget.value.clamp(0.0, 1.0).toDouble();

  @override
  void didUpdateWidget(VerticalVolumeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      value = widget.value.clamp(0.0, 1.0).toDouble();
    }
  }

  void onChanged(double next) {
    setState(() => value = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: OsColors.green,
        inactiveTrackColor: const Color(0xFF202225),
        trackHeight: 6,
        thumbColor: OsColors.text,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayColor: const Color(0x3323A559),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      child: RotatedBox(
        quarterTurns: 3,
        child: Slider(
          key: const ValueKey('vertical-volume-slider'),
          value: value,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class MemberVolumePopupEntry extends PopupMenuEntry<int> {
  const MemberVolumePopupEntry({
    super.key,
    required this.displayName,
    required this.initialVolume,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String displayName;
  final double initialVolume;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  double get height => 80;

  @override
  bool represents(int? value) => false;

  @override
  State<MemberVolumePopupEntry> createState() => _MemberVolumePopupEntryState();
}

class _MemberVolumePopupEntryState extends State<MemberVolumePopupEntry> {
  late double volume = widget.initialVolume.clamp(0.0, 2.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final percent = (volume * 100).round();
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: OsColors.blurpleSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.volume_up_outlined,
                    color: OsColors.blurple,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '调整音量',
                        style: TextStyle(
                          color: OsColors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OsColors.dim,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '$percent%',
                  key: const ValueKey('member-volume-percent'),
                  style: const TextStyle(
                    color: OsColors.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  const Text(
                    '0%',
                    style: TextStyle(color: OsColors.dim, fontSize: 11),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: OsColors.blurple,
                        inactiveTrackColor: const Color(0xFF3A3D44),
                        trackHeight: 4,
                        thumbColor: OsColors.text,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayColor: const Color(0x335865F2),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        key: const ValueKey('member-volume-slider'),
                        min: 0,
                        max: 2,
                        divisions: 200,
                        value: volume,
                        onChanged: (value) {
                          setState(() => volume = value);
                          widget.onChanged(value);
                        },
                        onChangeEnd: widget.onChangeEnd,
                      ),
                    ),
                  ),
                  const Text(
                    '200%',
                    style: TextStyle(color: OsColors.dim, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
