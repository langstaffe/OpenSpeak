import 'package:flutter/material.dart';

import 'os_theme.dart';
import 'smooth_scroll.dart';

const sectionStyle = TextStyle(
  color: OsColors.dim,
  fontWeight: FontWeight.w700,
  fontSize: 12,
  letterSpacing: 0,
);

class OsSettingsDialog extends StatelessWidget {
  const OsSettingsDialog({
    super.key,
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.child,
    this.leadingActions = const [],
    this.actions = const [],
    this.maxWidth = 520,
    this.compactHeader = false,
    this.resizable = true,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> leadingActions;
  final List<Widget> actions;
  final double maxWidth;
  final bool compactHeader;
  final bool resizable;

  @override
  Widget build(BuildContext context) {
    final frame = _ResizableDialogFrame(
      enabled: resizable,
      initialMaxWidth: maxWidth,
      initialMaxHeight: maxWidth >= 900 ? 840 : 720,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: OsColors.panel,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: OsColors.panelBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0xB3000000),
              blurRadius: 42,
              offset: Offset(0, 22),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              const Positioned(
                right: -105,
                top: -125,
                child: OsDialogGlow(size: 260, color: Color(0x245865F2)),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: compactHeader
                        ? const EdgeInsets.fromLTRB(20, 15, 16, 15)
                        : const EdgeInsets.fromLTRB(26, 24, 18, 20),
                    child: Row(
                      crossAxisAlignment: compactHeader
                          ? CrossAxisAlignment.center
                          : CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: compactHeader ? 40 : 48,
                          height: compactHeader ? 40 : 48,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [OsColors.blurple, Color(0xFF4752C4)],
                            ),
                            borderRadius: BorderRadius.circular(
                              compactHeader ? 13 : 15,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x4D5865F2),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Icon(
                            icon,
                            color: Colors.white,
                            size: compactHeader ? 21 : 24,
                          ),
                        ),
                        SizedBox(width: compactHeader ? 13 : 15),
                        Expanded(
                          child: compactHeader
                              ? Row(
                                  children: [
                                    if (eyebrow.isNotEmpty) ...[
                                      Text(
                                        eyebrow.toUpperCase(),
                                        style: const TextStyle(
                                          color: Color(0xFF8E98FF),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                      const Text(
                                        '  /  ',
                                        style: TextStyle(
                                          color: OsColors.icon,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                    Text(
                                      title,
                                      style: const TextStyle(
                                        color: OsColors.text,
                                        fontSize: 21,
                                        height: 1.1,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    if (subtitle.isNotEmpty) ...[
                                      const SizedBox(width: 10),
                                      Flexible(
                                        child: Text(
                                          subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: OsColors.dim,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      eyebrow.toUpperCase(),
                                      style: const TextStyle(
                                        color: Color(0xFF8E98FF),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 1.15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      title,
                                      style: const TextStyle(
                                        color: OsColors.text,
                                        fontSize: 24,
                                        height: 1.15,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      subtitle,
                                      style: const TextStyle(
                                        color: OsColors.dim,
                                        fontSize: 13,
                                        height: 1.4,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: '关闭',
                          child: IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF303238),
                              foregroundColor: OsColors.muted,
                              fixedSize: const Size(34, 34),
                              minimumSize: const Size(34, 34),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: OsColors.panelBorder),
                  Flexible(
                    child: resizable
                        ? Padding(
                            padding: EdgeInsets.fromLTRB(
                              compactHeader ? 18 : 26,
                              compactHeader ? 14 : 20,
                              compactHeader ? 18 : 26,
                              compactHeader ? 16 : 22,
                            ),
                            child: SizedBox.expand(child: child),
                          )
                        : SmoothSingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(
                              compactHeader ? 18 : 26,
                              compactHeader ? 14 : 20,
                              compactHeader ? 18 : 26,
                              compactHeader ? 16 : 22,
                            ),
                            child: child,
                          ),
                  ),
                  if (leadingActions.isNotEmpty || actions.isNotEmpty) ...[
                    const Divider(height: 1, color: OsColors.panelBorder),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 15, 26, 18),
                      child: Row(
                        children: [
                          for (
                            var index = 0;
                            index < leadingActions.length;
                            index++
                          ) ...[
                            if (index > 0) const SizedBox(width: 10),
                            leadingActions[index],
                          ],
                          const Spacer(),
                          for (
                            var index = 0;
                            index < actions.length;
                            index++
                          ) ...[
                            if (index > 0) const SizedBox(width: 10),
                            actions[index],
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (resizable) {
      return Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Center(child: frame),
        ),
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: frame,
    );
  }
}

enum _DialogResizeEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class _ResizableDialogFrame extends StatefulWidget {
  const _ResizableDialogFrame({
    required this.enabled,
    required this.initialMaxWidth,
    required this.initialMaxHeight,
    required this.child,
  });

  final bool enabled;
  final double initialMaxWidth;
  final double initialMaxHeight;
  final Widget child;

  @override
  State<_ResizableDialogFrame> createState() => _ResizableDialogFrameState();
}

class _ResizableDialogFrameState extends State<_ResizableDialogFrame> {
  static const minWidth = 620.0;
  static const minHeight = 420.0;
  static const edgeExtent = 8.0;
  static const cornerExtent = 16.0;

  final panelKey = GlobalKey();
  Size? size;
  Offset offset = Offset.zero;
  Size dragStartSize = Size.zero;
  Offset dragStartOffset = Offset.zero;
  Offset dragDelta = Offset.zero;

  void startResize(DragStartDetails details) {
    final box = panelKey.currentContext?.findRenderObject() as RenderBox?;
    dragStartSize = size ?? box?.size ?? Size.zero;
    dragStartOffset = offset;
    dragDelta = Offset.zero;
  }

  void resize(
    _DialogResizeEdge edge,
    DragUpdateDetails details,
    BoxConstraints viewport,
  ) {
    if (dragStartSize.isEmpty) return;
    dragDelta += details.delta;
    final left =
        edge == _DialogResizeEdge.left ||
        edge == _DialogResizeEdge.topLeft ||
        edge == _DialogResizeEdge.bottomLeft;
    final right =
        edge == _DialogResizeEdge.right ||
        edge == _DialogResizeEdge.topRight ||
        edge == _DialogResizeEdge.bottomRight;
    final top =
        edge == _DialogResizeEdge.top ||
        edge == _DialogResizeEdge.topLeft ||
        edge == _DialogResizeEdge.topRight;
    final bottom =
        edge == _DialogResizeEdge.bottom ||
        edge == _DialogResizeEdge.bottomLeft ||
        edge == _DialogResizeEdge.bottomRight;
    final requestedWidth =
        dragStartSize.width +
        (right ? dragDelta.dx : 0) -
        (left ? dragDelta.dx : 0);
    final requestedHeight =
        dragStartSize.height +
        (bottom ? dragDelta.dy : 0) -
        (top ? dragDelta.dy : 0);
    final viewportWidth = viewport.maxWidth.isFinite
        ? viewport.maxWidth
        : dragStartSize.width;
    final viewportHeight = viewport.maxHeight.isFinite
        ? viewport.maxHeight
        : dragStartSize.height;
    final maxWidth = left
        ? viewportWidth / 2 + dragStartOffset.dx + dragStartSize.width / 2
        : right
        ? viewportWidth / 2 - dragStartOffset.dx + dragStartSize.width / 2
        : viewportWidth;
    final maxHeight = top
        ? viewportHeight / 2 + dragStartOffset.dy + dragStartSize.height / 2
        : bottom
        ? viewportHeight / 2 - dragStartOffset.dy + dragStartSize.height / 2
        : viewportHeight;
    final nextWidth = requestedWidth
        .clamp(minWidth.clamp(0, maxWidth), maxWidth)
        .toDouble();
    final nextHeight = requestedHeight
        .clamp(minHeight.clamp(0, maxHeight), maxHeight)
        .toDouble();
    final widthDelta = nextWidth - dragStartSize.width;
    final heightDelta = nextHeight - dragStartSize.height;
    setState(() {
      size = Size(nextWidth, nextHeight);
      offset =
          dragStartOffset +
          Offset(
            left
                ? -widthDelta / 2
                : right
                ? widthDelta / 2
                : 0,
            top
                ? -heightDelta / 2
                : bottom
                ? heightDelta / 2
                : 0,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.initialMaxWidth,
          maxHeight: widget.initialMaxHeight,
        ),
        child: widget.child,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final panel = size == null
            ? ConstrainedBox(
                key: panelKey,
                constraints: BoxConstraints(
                  maxWidth: widget.initialMaxWidth,
                  maxHeight: widget.initialMaxHeight,
                ),
                child: widget.child,
              )
            : SizedBox(
                key: panelKey,
                width: size!.width,
                height: size!.height,
                child: widget.child,
              );
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Center(
            child: Transform.translate(
              offset: offset,
              child: Stack(
                clipBehavior: Clip.none,
                children: [panel, ..._resizeHandles(constraints)],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _resizeHandles(BoxConstraints viewport) {
    Widget handle({
      required _DialogResizeEdge edge,
      required MouseCursor cursor,
      double? left,
      double? right,
      double? top,
      double? bottom,
      double? width,
      double? height,
    }) {
      return Positioned(
        left: left,
        right: right,
        top: top,
        bottom: bottom,
        width: width,
        height: height,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            key: ValueKey('settings-dialog-resize-${edge.name}'),
            behavior: HitTestBehavior.opaque,
            onPanStart: startResize,
            onPanUpdate: (details) => resize(edge, details, viewport),
          ),
        ),
      );
    }

    return [
      handle(
        edge: _DialogResizeEdge.left,
        cursor: SystemMouseCursors.resizeLeftRight,
        left: 0,
        top: cornerExtent,
        bottom: cornerExtent,
        width: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.right,
        cursor: SystemMouseCursors.resizeLeftRight,
        right: 0,
        top: cornerExtent,
        bottom: cornerExtent,
        width: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.top,
        cursor: SystemMouseCursors.resizeUpDown,
        left: cornerExtent,
        right: cornerExtent,
        top: 0,
        height: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.bottom,
        cursor: SystemMouseCursors.resizeUpDown,
        left: cornerExtent,
        right: cornerExtent,
        bottom: 0,
        height: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.topLeft,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        left: 0,
        top: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
      handle(
        edge: _DialogResizeEdge.topRight,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        right: 0,
        top: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
      handle(
        edge: _DialogResizeEdge.bottomLeft,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        left: 0,
        bottom: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
      handle(
        edge: _DialogResizeEdge.bottomRight,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        right: 0,
        bottom: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
    ];
  }
}

class OsSplitSettingsBody extends StatelessWidget {
  const OsSplitSettingsBody({
    super.key,
    required this.navigation,
    required this.content,
    this.showNavigation = true,
  });

  final List<Widget> navigation;
  final Widget content;
  final bool showNavigation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 370,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!showNavigation) return content;
          if (constraints.maxWidth < 560) {
            return Column(
              children: [
                Container(
                  height: 58,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF222429),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: OsColors.panelBorder),
                  ),
                  child: Row(
                    children: [
                      for (final entry in navigation) Expanded(child: entry),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(child: content),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 205,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF222429),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: OsColors.panelBorder),
                ),
                child: SmoothListView(
                  padding: EdgeInsets.zero,
                  children: navigation,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }
}

class OsSettingsNavEntry extends StatelessWidget {
  const OsSettingsNavEntry({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? OsColors.blurpleSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(11),
          hoverColor: OsColors.rowSelected,
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: selected
                  ? const Border(
                      left: BorderSide(color: OsColors.blurple, width: 3),
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected ? const Color(0xFF929CFF) : OsColors.dim,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? OsColors.text : OsColors.muted,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF34373D),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        color: OsColors.dim,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                      ),
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

class OsSettingsNavSection extends StatelessWidget {
  const OsSettingsNavSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 10, 8, 5),
      child: Text(
        label,
        style: const TextStyle(
          color: OsColors.icon,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class OsSettingsPage extends StatelessWidget {
  const OsSettingsPage({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF222429),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OsColors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: OsColors.blurpleSoft,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: OsColors.blurple, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: OsColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: OsColors.dim,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: OsColors.panelBorder),
          Expanded(
            child: SmoothSingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: child,
            ),
          ),
          if (footer != null) ...[
            const Divider(height: 1, color: OsColors.panelBorder),
            Padding(padding: const EdgeInsets.all(12), child: footer),
          ],
        ],
      ),
    );
  }
}

class OsDialogGlow extends StatelessWidget {
  const OsDialogGlow({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color, blurRadius: size / 2, spreadRadius: 20),
          ],
        ),
      ),
    );
  }
}
