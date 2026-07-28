import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'openspeak_api.dart';
import 'os_avatar.dart';
import 'os_theme.dart';

class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count, this.compact = false});

  final int count;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final label = count > 99 ? '99+' : '$count';
    final minSize = compact ? 18.0 : 22.0;
    return Container(
      constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: OsColors.danger,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          color: Colors.white,
          fontSize: compact ? 10 : 12,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

class ServerBubble extends StatefulWidget {
  const ServerBubble({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
    this.tooltip,
    this.color,
    this.foregroundColor,
    this.badgeCount = 0,
    this.onSecondaryTapDown,
    this.hoverColor,
    this.imageUri,
    this.caption,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final Color? foregroundColor;
  final int badgeCount;
  final GestureTapDownCallback? onSecondaryTapDown;
  final Color? hoverColor;
  final Uri? imageUri;
  final String? caption;

  @override
  State<ServerBubble> createState() => _ServerBubbleState();
}

class _ServerBubbleState extends State<ServerBubble> {
  bool hovering = false;

  bool get interactive =>
      widget.onTap != null || widget.onSecondaryTapDown != null;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Tooltip(
          message: widget.tooltip ?? widget.caption ?? widget.label,
          child: MouseRegion(
            onEnter: interactive && widget.hoverColor != null
                ? (_) => setState(() => hovering = true)
                : null,
            onExit: interactive && widget.hoverColor != null
                ? (_) => setState(() => hovering = false)
                : null,
            child: InkWell(
              onTap: widget.onTap,
              onSecondaryTapDown: widget.onSecondaryTapDown,
              mouseCursor: interactive
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                width: 64,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: hovering && widget.hoverColor != null
                                  ? widget.hoverColor
                                  : widget.color ??
                                        (widget.selected
                                            ? OsColors.blurple
                                            : OsColors.content),
                              shape: BoxShape.circle,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: widget.imageUri == null
                                ? Text(
                                    widget.label,
                                    style: TextStyle(
                                      color: widget.foregroundColor,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  )
                                : Image.network(
                                    widget.imageUri.toString(),
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Center(
                                      child: Text(
                                        widget.label,
                                        style: TextStyle(
                                          color: widget.foregroundColor,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                          if (widget.badgeCount > 0)
                            Positioned(
                              right: -3,
                              top: -4,
                              child: UnreadBadge(
                                count: widget.badgeCount,
                                compact: true,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.caption != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        widget.caption!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: widget.selected ? OsColors.text : OsColors.dim,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ServerHeader extends StatelessWidget {
  const ServerHeader({
    super.key,
    required this.serverName,
    this.showAvatar = false,
    this.avatarUri,
    required this.menuOpen,
    required this.onMenuPressed,
  });

  final String serverName;
  final bool showAvatar;
  final Uri? avatarUri;
  final bool menuOpen;
  final GestureTapUpCallback onMenuPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 16, right: 10),
      decoration: const BoxDecoration(
        color: OsColors.sidebar,
        border: Border(bottom: BorderSide(color: OsColors.divider)),
      ),
      child: Row(
        children: [
          if (showAvatar) ...[
            OsUserAvatar(
              displayName: serverName,
              size: 34,
              avatarUri: avatarUri,
              backgroundColor: OsColors.blurple,
            ),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: Text(
              serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: OsColors.text,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
          if (!kIsWeb)
            Tooltip(
              message: '服务器菜单',
              child: Material(
                color: menuOpen ? OsColors.rowSelected : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTapUp: onMenuPressed,
                  mouseCursor: SystemMouseCursors.click,
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.menu, color: OsColors.text, size: 22),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class MobileChannelCard extends StatelessWidget {
  const MobileChannelCard({
    super.key,
    required this.channel,
    required this.selected,
    required this.unreadCount,
    required this.mentionCount,
    required this.members,
    required this.voiceStatesByUserId,
    required this.api,
    required this.avatarToken,
    required this.onOpen,
    required this.onDoubleTap,
    this.onLongPressStart,
  });

  final Channel channel;
  final bool selected;
  final int unreadCount;
  final int mentionCount;
  final List<PresenceUser> members;
  final Map<String, VoiceState> voiceStatesByUserId;
  final OpenSpeakApi? api;
  final String? avatarToken;
  final VoidCallback onOpen;
  final VoidCallback onDoubleTap;
  final GestureLongPressStartCallback? onLongPressStart;

  @override
  Widget build(BuildContext context) {
    final hasUnread = unreadCount > 0 || mentionCount > 0;
    final visibleMembers = members.take(2).toList();
    final memberNames = visibleMembers
        .map(
          (member) => member.displayName.trim().isEmpty
              ? member.userId
              : member.displayName.trim(),
        )
        .join('、');
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GestureDetector(
        onLongPressStart: onLongPressStart,
        child: Material(
          color: selected ? OsColors.rowSelected : OsColors.rowHover,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: onDoubleTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 58),
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? OsColors.blurple : OsColors.panelBorder,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.tag,
                        color: selected || hasUnread
                            ? OsColors.text
                            : OsColors.dim,
                        size: 21,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected || hasUnread
                                ? OsColors.text
                                : OsColors.muted,
                            fontSize: 15,
                            fontWeight: selected || hasUnread
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            key: ValueKey('mobile-channel-open-${channel.id}'),
                            tooltip: '进入频道聊天',
                            onPressed: onOpen,
                            padding: EdgeInsets.zero,
                            alignment: Alignment.center,
                            style: IconButton.styleFrom(
                              backgroundColor: OsColors.sidebarBottom,
                              foregroundColor: OsColors.dim,
                              overlayColor: Colors.transparent,
                              splashFactory: NoSplash.splashFactory,
                              side: const BorderSide(
                                color: OsColors.panelBorder,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              fixedSize: const Size(40, 40),
                              minimumSize: const Size(40, 40),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(
                              Icons.chevron_right_rounded,
                              size: 28,
                            ),
                          ),
                          if (hasUnread)
                            Positioned(
                              left: -7,
                              top: -5,
                              child: IgnorePointer(
                                child: UnreadBadge(
                                  count: unreadCount > 0
                                      ? unreadCount
                                      : mentionCount,
                                  compact: true,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  if (visibleMembers.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const SizedBox(width: 30),
                        for (final member in visibleMembers)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: ChannelMemberSpeakingAvatar(
                              displayName: member.displayName.trim().isEmpty
                                  ? member.userId
                                  : member.displayName.trim(),
                              online: member.online,
                              voiceState: voiceStatesByUserId[member.userId],
                              avatarUri: member.avatarVersion > 0
                                  ? api?.userAvatarUri(
                                      member.userId,
                                      member.avatarVersion,
                                      small: true,
                                    )
                                  : null,
                              avatarToken: avatarToken,
                            ),
                          ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            members.length > visibleMembers.length
                                ? '$memberNames 等 ${members.length} 人在线'
                                : '$memberNames 在线',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.dim,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MobileDirectUserTile extends StatelessWidget {
  const MobileDirectUserTile({
    super.key,
    required this.user,
    required this.voiceState,
    required this.channelName,
    required this.unreadCount,
    required this.avatarUri,
    required this.avatarToken,
    required this.onTap,
  });

  final PresenceUser user;
  final VoiceState? voiceState;
  final String? channelName;
  final int unreadCount;
  final Uri? avatarUri;
  final String? avatarToken;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displayName = user.displayName.trim().isEmpty
        ? user.userId
        : user.displayName.trim();
    return Material(
      color: OsColors.rowHover,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 68),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: OsColors.panelBorder),
          ),
          child: Row(
            children: [
              ChannelMemberSpeakingAvatar(
                displayName: displayName,
                online: user.online,
                voiceState: voiceState,
                avatarUri: avatarUri,
                avatarToken: avatarToken,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      channelName == null ? '在线' : '在 #$channelName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.dim,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              UnreadBadge(count: unreadCount, compact: true),
              const SizedBox(width: 7),
              const Icon(
                Icons.chevron_right_rounded,
                color: OsColors.dim,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileVoiceActionCard extends StatelessWidget {
  const MobileVoiceActionCard({
    super.key,
    required this.label,
    this.icon,
    this.iconWidget,
    required this.onTap,
    this.active = false,
    this.enabled = true,
  }) : assert(icon != null || iconWidget != null);

  final String label;
  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback onTap;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final foreground = !enabled
        ? OsColors.icon
        : active
        ? const Color(0xFF929CFF)
        : OsColors.muted;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: active ? OsColors.blurpleSoft : OsColors.panelRaised,
        borderRadius: BorderRadius.circular(15),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: active ? OsColors.blurple : OsColors.panelBorder,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                iconWidget ?? Icon(icon, color: foreground, size: 25),
                const SizedBox(height: 7),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImmediateChannelInkWell extends StatefulWidget {
  const _ImmediateChannelInkWell({
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
    required this.child,
  });

  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final Widget child;

  @override
  State<_ImmediateChannelInkWell> createState() =>
      _ImmediateChannelInkWellState();
}

class _ImmediateChannelInkWellState extends State<_ImmediateChannelInkWell> {
  Offset? currentPrimaryDownPosition;
  bool currentDoubleTapCandidate = false;
  Offset? lastPrimaryDownPosition;
  bool tapSeriesMinTimeElapsed = false;
  Timer? tapSeriesMinTimer;
  Timer? tapSeriesTimer;

  void handlePointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    widget.onTap();
    currentPrimaryDownPosition = event.position;
    currentDoubleTapCandidate = isDoubleTapCandidate(event.position);
    if (currentDoubleTapCandidate) {
      tapSeriesTimer?.cancel();
      tapSeriesTimer = null;
    }
  }

  bool isDoubleTapCandidate(Offset position) =>
      lastPrimaryDownPosition != null &&
      tapSeriesMinTimeElapsed &&
      (position - lastPrimaryDownPosition!).distance <= kDoubleTapSlop;

  void handleTap() {
    final currentPosition = currentPrimaryDownPosition;
    if (currentPosition == null) return;
    final doubleTap = currentDoubleTapCandidate;
    currentPrimaryDownPosition = null;
    currentDoubleTapCandidate = false;
    clearTapSeries();
    if (doubleTap) {
      widget.onDoubleTap();
    } else {
      lastPrimaryDownPosition = currentPosition;
      tapSeriesMinTimer = Timer(
        kDoubleTapMinTime,
        () => tapSeriesMinTimeElapsed = true,
      );
      tapSeriesTimer = Timer(kDoubleTapTimeout, clearTapSeries);
    }
  }

  void handleTapCancel() {
    currentPrimaryDownPosition = null;
    currentDoubleTapCandidate = false;
    clearTapSeries();
  }

  void clearTapSeries() {
    tapSeriesMinTimer?.cancel();
    tapSeriesMinTimer = null;
    tapSeriesTimer?.cancel();
    tapSeriesTimer = null;
    tapSeriesMinTimeElapsed = false;
    lastPrimaryDownPosition = null;
  }

  @override
  void dispose() {
    clearTapSeries();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    onTap: widget.onTap,
    child: Listener(
      onPointerDown: handlePointerDown,
      child: InkWell(
        excludeFromSemantics: true,
        enableFeedback: false,
        onTap: handleTap,
        onTapCancel: handleTapCancel,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: widget.child,
      ),
    ),
  );
}

class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.channel,
    required this.selected,
    required this.unreadCount,
    required this.mentionCount,
    required this.members,
    required this.directUnreadCounts,
    required this.voiceStatesByUserId,
    required this.currentUserId,
    required this.currentUserMicrophoneUnavailable,
    required this.currentUserSpeakerUnavailable,
    this.reorderIndex,
    this.api,
    this.avatarToken,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
    required this.onMemberTap,
    required this.onMemberSecondaryTapDown,
    this.canMoveMembers = false,
    this.onMemberDropped,
  });
  final Channel channel;
  final bool selected;
  final int unreadCount;
  final int mentionCount;
  final List<PresenceUser> members;
  final Map<String, int> directUnreadCounts;
  final Map<String, VoiceState> voiceStatesByUserId;
  final String? currentUserId;
  final bool currentUserMicrophoneUnavailable;
  final bool currentUserSpeakerUnavailable;
  final int? reorderIndex;
  final OpenSpeakApi? api;
  final String? avatarToken;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final ValueChanged<PresenceUser> onMemberTap;
  final void Function(PresenceUser, TapDownDetails) onMemberSecondaryTapDown;
  final bool canMoveMembers;
  final ValueChanged<PresenceUser>? onMemberDropped;

  @override
  Widget build(BuildContext context) {
    final hasUnread = unreadCount > 0 || mentionCount > 0;
    final unreadBadgeCount = unreadCount > 0 ? unreadCount : mentionCount;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Material(
            color: selected ? OsColors.rowSelected : OsColors.rowHover,
            borderRadius: BorderRadius.circular(4),
            clipBehavior: Clip.antiAlias,
            child: _ImmediateChannelInkWell(
              onTap: onTap,
              onDoubleTap: onDoubleTap,
              onSecondaryTapDown: onSecondaryTapDown,
              child: SizedBox(
                height: 38,
                child: Stack(
                  children: [
                    if (hasUnread)
                      const Positioned(
                        left: 0,
                        top: 6,
                        bottom: 6,
                        child: ColoredBox(
                          color: OsColors.blurple,
                          child: SizedBox(width: 3),
                        ),
                      ),
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.only(
                        left: 16,
                        right: reorderIndex != null
                            ? (hasUnread ? 68 : 42)
                            : (hasUnread ? 44 : 16),
                      ),
                      minLeadingWidth: 16,
                      leading: Icon(
                        Icons.tag,
                        size: 17,
                        color: hasUnread ? OsColors.text : OsColors.dim,
                      ),
                      title: Text(
                        channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected || hasUnread
                              ? OsColors.text
                              : OsColors.muted,
                          fontWeight: selected || hasUnread
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (hasUnread)
                      Positioned(
                        right: reorderIndex == null ? 8 : 34,
                        top: 5,
                        child: UnreadBadge(
                          count: unreadBadgeCount,
                          compact: true,
                        ),
                      ),
                    if (reorderIndex != null)
                      Positioned(
                        right: 6,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: ReorderableDragStartListener(
                            index: reorderIndex!,
                            child: const MouseRegion(
                              cursor: SystemMouseCursors.grab,
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 20,
                                color: OsColors.dim,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        for (final member in members)
          ChannelMemberSubTile(
            user: member,
            voiceState: voiceStatesByUserId[member.userId],
            microphoneUnavailable:
                member.userId == currentUserId &&
                currentUserMicrophoneUnavailable,
            speakerUnavailable:
                member.userId == currentUserId && currentUserSpeakerUnavailable,
            unreadCount: directUnreadCounts[member.userId] ?? 0,
            api: api,
            avatarToken: avatarToken,
            onTap: () => onMemberTap(member),
            onSecondaryTapDown: (details) =>
                onMemberSecondaryTapDown(member, details),
            draggable: canMoveMembers && member.userId != currentUserId,
          ),
      ],
    );
    return DragTarget<PresenceUser>(
      onWillAcceptWithDetails: (details) =>
          canMoveMembers &&
          details.data.userId != currentUserId &&
          details.data.currentChannelId != channel.id,
      onAcceptWithDetails: (details) => onMemberDropped?.call(details.data),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border.all(color: OsColors.blurple, width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: content,
      ),
    );
  }
}

class ChannelMemberSubTile extends StatelessWidget {
  const ChannelMemberSubTile({
    super.key,
    required this.user,
    required this.voiceState,
    this.microphoneUnavailable = false,
    this.speakerUnavailable = false,
    required this.unreadCount,
    this.api,
    this.avatarToken,
    required this.onTap,
    this.onSecondaryTapDown,
    this.draggable = false,
  });

  final PresenceUser user;
  final VoiceState? voiceState;
  final bool microphoneUnavailable;
  final bool speakerUnavailable;
  final int unreadCount;
  final OpenSpeakApi? api;
  final String? avatarToken;
  final VoidCallback onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final bool draggable;

  @override
  Widget build(BuildContext context) {
    final displayName = user.displayName.trim().isNotEmpty
        ? user.displayName.trim()
        : user.userId;
    final online = user.online;

    final tile = Padding(
      padding: const EdgeInsets.only(top: 1, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          mouseCursor: draggable
              ? SystemMouseCursors.grab
              : SystemMouseCursors.click,
          hoverColor: OsColors.rowSelected,
          splashColor: Colors.transparent,
          highlightColor: OsColors.rowSelected,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ChannelMemberSpeakingAvatar(
                      displayName: displayName,
                      online: online,
                      voiceState: voiceState,
                      avatarUri: user.avatarVersion > 0
                          ? api?.userAvatarUri(
                              user.userId,
                              user.avatarVersion,
                              small: true,
                            )
                          : null,
                      avatarToken: avatarToken,
                    ),
                    Positioned(
                      right: -5,
                      top: -4,
                      child: UnreadBadge(count: unreadCount, compact: true),
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: ChannelMemberVoiceBadge(
                        voiceState: voiceState,
                        microphoneUnavailable: microphoneUnavailable,
                        speakerUnavailable: speakerUnavailable,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: online ? OsColors.text : OsColors.dim,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (voiceState?.screenSharing == true) ...[
                  Tooltip(
                    message: '正在分享屏幕',
                    child: Semantics(
                      label: '正在分享屏幕',
                      child: const Icon(
                        key: ValueKey('channel-member-screen-share-badge'),
                        Icons.screen_share_rounded,
                        size: 20,
                        color: OsColors.green,
                      ),
                    ),
                  ),
                  if (user.role == 'owner' || user.role == 'admin')
                    const SizedBox(width: 6),
                ],
                ChannelMemberRoleBadge(role: user.role),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
    if (!draggable) return tile;
    return Draggable<PresenceUser>(
      data: user,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: OsColors.rowSelected,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 208,
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 16),
              ChannelMemberSpeakingAvatar(
                displayName: displayName,
                online: online,
                voiceState: voiceState,
                avatarUri: user.avatarVersion > 0
                    ? api?.userAvatarUri(
                        user.userId,
                        user.avatarVersion,
                        small: true,
                      )
                    : null,
                avatarToken: avatarToken,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: OsColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }
}

class ChannelMemberRoleBadge extends StatelessWidget {
  const ChannelMemberRoleBadge({super.key, required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label, key) = switch (role) {
      'owner' => (
        Icons.bookmark_rounded,
        const Color(0xFFFFC928),
        '服主',
        const ValueKey('channel-member-owner-badge'),
      ),
      'admin' => (
        Icons.stars_rounded,
        const Color(0xFF3297F5),
        '管理员',
        const ValueKey('channel-member-admin-badge'),
      ),
      _ => (null, null, null, null),
    };
    if (icon == null || color == null || label == null || key == null) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(key: key, icon, size: 20, color: color),
      ),
    );
  }
}

class ChannelMemberVoiceBadge extends StatelessWidget {
  const ChannelMemberVoiceBadge({
    super.key,
    required this.voiceState,
    this.microphoneUnavailable = false,
    this.speakerUnavailable = false,
  });

  final VoiceState? voiceState;
  final bool microphoneUnavailable;
  final bool speakerUnavailable;

  @override
  Widget build(BuildContext context) {
    if (microphoneUnavailable || speakerUnavailable) {
      return Row(
        key: const ValueKey('channel-member-device-unavailable-badge'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (microphoneUnavailable)
            _icon(Icons.mic_off, color: OsColors.danger, label: '未检测到麦克风'),
          if (speakerUnavailable)
            _icon(Icons.volume_off, color: OsColors.danger, label: '未检测到扬声器'),
        ],
      );
    }
    final state = voiceState;
    if (state?.deafened == true) {
      return _icon(Icons.volume_off);
    }
    if (state?.muted == true) {
      return _icon(Icons.mic_off);
    }
    return const SizedBox.shrink();
  }

  Widget _icon(IconData icon, {Color color = OsColors.dim, String? label}) {
    final badge = SizedBox(
      width: 11,
      height: 11,
      child: OverflowBox(
        minWidth: 16,
        maxWidth: 16,
        minHeight: 16,
        maxHeight: 16,
        child: Container(
          decoration: BoxDecoration(
            color: OsColors.sidebar,
            shape: BoxShape.circle,
            border: Border.all(color: OsColors.sidebar, width: 2),
          ),
          child: Icon(icon, size: 11, color: color),
        ),
      ),
    );
    return Semantics(
      label: label,
      child: SizedBox(
        key: const ValueKey('channel-member-voice-badge'),
        child: badge,
      ),
    );
  }
}

class ChannelMemberSpeakingAvatar extends StatefulWidget {
  const ChannelMemberSpeakingAvatar({
    super.key,
    required this.displayName,
    required this.online,
    required this.voiceState,
    this.avatarUri,
    this.avatarToken,
  });

  final String displayName;
  final bool online;
  final VoiceState? voiceState;
  final Uri? avatarUri;
  final String? avatarToken;

  @override
  State<ChannelMemberSpeakingAvatar> createState() =>
      _ChannelMemberSpeakingAvatarState();
}

class _ChannelMemberSpeakingAvatarState
    extends State<ChannelMemberSpeakingAvatar> {
  static const speakingReleaseDelay = Duration(milliseconds: 200);
  Timer? hideTimer;
  late bool showSpeaking;

  bool get speaking =>
      widget.voiceState?.speaking == true &&
      widget.voiceState?.muted != true &&
      widget.voiceState?.deafened != true;

  bool get voiceBlocked =>
      widget.voiceState?.muted == true || widget.voiceState?.deafened == true;

  @override
  void initState() {
    super.initState();
    showSpeaking = speaking;
  }

  @override
  void didUpdateWidget(covariant ChannelMemberSpeakingAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (voiceBlocked) {
      hideTimer?.cancel();
      if (showSpeaking) setState(() => showSpeaking = false);
      return;
    }
    if (speaking) {
      hideTimer?.cancel();
      if (!showSpeaking) setState(() => showSpeaking = true);
      return;
    }
    if (!showSpeaking || hideTimer?.isActive == true) return;
    hideTimer = Timer(speakingReleaseDelay, () {
      if (!mounted || speaking) return;
      setState(() => showSpeaking = false);
    });
  }

  @override
  void dispose() {
    hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      key: ValueKey(
        showSpeaking
            ? 'channel-member-speaking-avatar-active'
            : 'channel-member-speaking-avatar-idle',
      ),
      duration: showSpeaking
          ? Duration.zero
          : const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: showSpeaking ? OsColors.green : Colors.transparent,
          width: 2,
        ),
      ),
      child: OsUserAvatar(
        displayName: widget.displayName,
        size: 30,
        avatarUri: widget.avatarUri,
        avatarToken: widget.avatarToken,
        backgroundColor: widget.online
            ? OsColors.blurple
            : const Color(0xFF36393F),
      ),
    );
  }
}
