import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'os_theme.dart';

List<ContextMenuButtonItem> osLocalizedContextMenuItems(
  List<ContextMenuButtonItem> items,
) {
  return items
      .map((item) {
        return switch (item.type) {
          ContextMenuButtonType.copy => item.copyWith(label: '复制'),
          ContextMenuButtonType.cut => item.copyWith(label: '剪切'),
          ContextMenuButtonType.paste => item.copyWith(label: '粘贴'),
          _ => item,
        };
      })
      .toList(growable: false);
}

List<ContextMenuButtonItem> osEditableContextMenuItems(
  List<ContextMenuButtonItem> items,
  VoidCallback onPaste,
) {
  final localized = osLocalizedContextMenuItems(items);
  if (localized.any((item) => item.type == ContextMenuButtonType.paste)) {
    return localized;
  }
  return [
    ...localized,
    ContextMenuButtonItem(
      onPressed: onPaste,
      type: ContextMenuButtonType.paste,
      label: '粘贴',
    ),
  ];
}

Widget osEditableTextContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return OsCompactTextSelectionToolbar(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: osEditableContextMenuItems(
      editableTextState.contextMenuButtonItems,
      () =>
          unawaited(editableTextState.pasteText(SelectionChangedCause.toolbar)),
    ),
  );
}

class OsCompactTextSelectionToolbar extends StatelessWidget {
  const OsCompactTextSelectionToolbar({
    super.key,
    required this.anchors,
    required this.buttonItems,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  static const _screenPadding = 8.0;

  double _width(BuildContext context) {
    var widest = 0.0;
    for (final item in buttonItems) {
      final painter = TextPainter(
        text: TextSpan(
          text: AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
          style: const TextStyle(fontSize: 14),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      widest = math.max(widest, painter.width);
    }
    return (widest + 28).clamp(72, 222);
  }

  @override
  Widget build(BuildContext context) {
    if (buttonItems.isEmpty) return const SizedBox.shrink();
    final platform = Theme.of(context).platform;
    if (platform != TargetPlatform.macOS &&
        platform != TargetPlatform.windows &&
        platform != TargetPlatform.linux) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: anchors,
        buttonItems: buttonItems,
      );
    }

    final paddingAbove = MediaQuery.paddingOf(context).top + _screenPadding;
    final buttons = platform == TargetPlatform.macOS
        ? buttonItems
              .map((item) => _OsMacTextSelectionButton(item: item))
              .toList(growable: false)
        : AdaptiveTextSelectionToolbar.getAdaptiveButtons(
            context,
            buttonItems,
          ).toList(growable: false);
    final column = Column(mainAxisSize: MainAxisSize.min, children: buttons);
    final width = _width(context);
    final toolbar = platform == TargetPlatform.macOS
        ? _OsMacTextSelectionSurface(width: width, child: column)
        : SizedBox(
            key: const ValueKey('compact-text-selection-toolbar'),
            width: width,
            child: Material(
              borderRadius: BorderRadius.circular(7),
              clipBehavior: Clip.antiAlias,
              elevation: 1,
              type: MaterialType.card,
              child: column,
            ),
          );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        paddingAbove,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: anchors.primaryAnchor - Offset(_screenPadding, paddingAbove),
        ),
        child: toolbar,
      ),
    );
  }
}

Future<int?> showOsCompactContextMenu(
  BuildContext context,
  Offset position,
  List<String> labels,
) => showGeneralDialog<int>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭菜单',
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (menuContext, _, _) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: () => Navigator.pop(menuContext),
    onSecondaryTap: () => Navigator.pop(menuContext),
    child: Material(
      color: Colors.transparent,
      child: OsCompactTextSelectionToolbar(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: position),
        buttonItems: [
          for (var index = 0; index < labels.length; index++)
            ContextMenuButtonItem(
              onPressed: () => Navigator.pop(menuContext, index),
              label: labels[index],
            ),
        ],
      ),
    ),
  ),
);

class _OsMacTextSelectionButton extends StatelessWidget {
  const _OsMacTextSelectionButton({required this.item});

  final ContextMenuButtonItem item;

  @override
  Widget build(BuildContext context) {
    final label = AdaptiveTextSelectionToolbar.getButtonLabel(context, item);
    final primary = CupertinoTheme.of(context).primaryColor;
    final normal = const CupertinoDynamicColor.withBrightness(
      color: CupertinoColors.black,
      darkColor: CupertinoColors.white,
    ).resolveFrom(context);
    final contrasting = CupertinoTheme.of(context).primaryContrastingColor;
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: item.onPressed,
        style: ButtonStyle(
          alignment: Alignment.center,
          minimumSize: const WidgetStatePropertyAll(Size.zero),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) ? contrasting : normal,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered)
                ? primary
                : Colors.transparent,
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            letterSpacing: -0.15,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _OsMacTextSelectionSurface extends StatelessWidget {
  const _OsMacTextSelectionSurface({required this.width, required this.child});

  final double width;
  final Widget child;

  static const _saturationMatrix = <double>[
    2.574,
    -1.43,
    -0.144,
    0,
    0,
    -0.426,
    1.57,
    -0.144,
    0,
    0,
    -0.426,
    -1.43,
    2.856,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(8));
    return Container(
      key: const ValueKey('compact-text-selection-toolbar'),
      width: width,
      clipBehavior: Clip.hardEdge,
      decoration: const ShapeDecoration(
        shadows: [
          BoxShadow(
            color: Color.fromARGB(60, 0, 0, 0),
            blurRadius: 10,
            spreadRadius: 0.5,
            offset: Offset(0, 4),
          ),
        ],
        shape: RoundedSuperellipseBorder(borderRadius: radius),
      ),
      child: BackdropFilter(
        filter: ui.ImageFilter.compose(
          outer: const ColorFilter.matrix(_saturationMatrix),
          inner: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        ),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: const CupertinoDynamicColor.withBrightness(
              color: Color(0xB2FFFFFF),
              darkColor: Color(0xB2303030),
            ).resolveFrom(context),
            shape: RoundedSuperellipseBorder(
              side: BorderSide(
                color: const CupertinoDynamicColor.withBrightness(
                  color: Color(0xFFB8B8B8),
                  darkColor: Color(0xFF5B5B5B),
                ).resolveFrom(context),
              ),
              borderRadius: radius,
            ),
          ),
          child: Padding(padding: const EdgeInsets.all(6), child: child),
        ),
      ),
    );
  }
}

class OsPopupMenuRow extends StatelessWidget {
  const OsPopupMenuRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFFF6B6E) : OsColors.text;
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: danger ? const Color(0x333C252A) : OsColors.blurpleSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 18,
            color: danger ? OsColors.danger : OsColors.blurple,
          ),
        ),
        const SizedBox(width: 11),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              subtitle,
              style: const TextStyle(
                color: OsColors.dim,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
