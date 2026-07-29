import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        LogicalKeyboardKey;

import 'attachment_transfer_controller.dart';
import 'audio_attachment_metadata.dart';
import 'chat_attachment_widgets.dart';
import 'clipboard_image.dart';
import 'client_link_preview.dart';
import 'openspeak_api.dart';
import 'os_avatar.dart';
import 'os_context_menu.dart';
import 'os_theme.dart';
import 'responsive_layout.dart';

class ChatMessageEntry extends StatelessWidget {
  const ChatMessageEntry({
    super.key,
    required this.sentAt,
    required this.previousSentAt,
    required this.child,
  });

  final DateTime? sentAt;
  final DateTime? previousSentAt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (startsNewLocalDay(sentAt, previousSentAt))
          ChatDateDivider(date: sentAt!),
        child,
      ],
    );
  }
}

class ChatDateDivider extends StatelessWidget {
  const ChatDateDivider({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const Expanded(
            child: Divider(height: 1, thickness: 1, color: OsColors.dim),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              localDateLabel(date),
              style: const TextStyle(color: OsColors.dim, fontSize: 11),
            ),
          ),
          const Expanded(
            child: Divider(height: 1, thickness: 1, color: OsColors.dim),
          ),
        ],
      ),
    );
  }
}

class ChatMessageRemovalNotice extends StatelessWidget {
  const ChatMessageRemovalNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Center(
      child: Text(
        text,
        style: const TextStyle(color: OsColors.dim, fontSize: 11),
      ),
    ),
  );
}

class ChatMessageRow extends StatelessWidget {
  const ChatMessageRow({
    super.key,
    required this.body,
    required this.attachment,
    this.attachmentDownloadsEnabled = true,
    required this.sentAt,
    required this.senderName,
    required this.mine,
    this.avatarFile,
    this.avatarRevision = 0,
    this.avatarUri,
    this.avatarToken,
    required this.ensureCached,
    required this.loadImagePreview,
    required this.loadAudioMetadata,
    required this.linkPreviewFallback,
    required this.linkPreviewFuture,
    required this.onOpen,
    required this.onSaveAs,
    required this.onOpenLink,
    required this.downloadTask,
    required this.onCancelDownload,
    required this.activeAudioFileId,
    required this.audioLoadingFileId,
    required this.audioPlaying,
    required this.audioPosition,
    required this.audioDuration,
    required this.onToggleAudio,
    required this.onSeekAudio,
    this.messageActionLabel,
    this.onMessageAction,
    this.onMessageContextMenu,
  });

  final String body;
  final ChatAttachment? attachment;
  final bool attachmentDownloadsEnabled;
  final DateTime? sentAt;
  final String senderName;
  final bool mine;
  final File? avatarFile;
  final int avatarRevision;
  final Uri? avatarUri;
  final String? avatarToken;
  final Future<File> Function(ChatAttachment attachment) ensureCached;
  final Future<CachedImagePreview> Function(ChatAttachment attachment)
  loadImagePreview;
  final Future<AudioAttachmentMetadata> Function(ChatAttachment attachment)
  loadAudioMetadata;
  final LinkPreview? linkPreviewFallback;
  final Future<LinkPreview?>? linkPreviewFuture;
  final Future<void> Function(ChatAttachment attachment) onOpen;
  final Future<void> Function(ChatAttachment attachment) onSaveAs;
  final Future<void> Function(String url) onOpenLink;
  final TransferTask? downloadTask;
  final void Function(ChatAttachment attachment) onCancelDownload;
  final String? activeAudioFileId;
  final String? audioLoadingFileId;
  final bool audioPlaying;
  final Duration audioPosition;
  final Duration audioDuration;
  final Future<void> Function(ChatAttachment attachment) onToggleAudio;
  final Future<void> Function(Duration position) onSeekAudio;
  final String? messageActionLabel;
  final VoidCallback? onMessageAction;
  final void Function(Offset position)? onMessageContextMenu;

  Future<void> _showTextBubbleContextMenu(
    BuildContext context,
    Offset position,
  ) async {
    final hasAction = messageActionLabel != null && onMessageAction != null;
    final selected = await showOsCompactContextMenu(context, position, [
      '复制',
      if (hasAction) messageActionLabel!,
    ]);
    if (selected == 0) {
      await Clipboard.setData(ClipboardData(text: body));
    } else if (selected == 1 && hasAction) {
      onMessageAction!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatar = ChatAvatar(
      name: senderName,
      mine: mine,
      avatarFile: avatarFile,
      avatarRevision: avatarRevision,
      avatarUri: avatarUri,
      avatarToken: avatarToken,
    );
    final currentAttachment = attachment;
    final imageAttachment =
        currentAttachment != null && currentAttachment.isImage;
    final audioAttachment =
        currentAttachment != null && currentAttachment.isAudio;
    final header = Row(
      mainAxisSize: MainAxisSize.min,
      textDirection: mine ? TextDirection.rtl : TextDirection.ltr,
      children: [
        Flexible(
          child: Text(
            senderName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: OsColors.text,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          shortTime(sentAt),
          style: const TextStyle(color: OsColors.dim, fontSize: 11),
        ),
      ],
    );
    final content = currentAttachment != null && !attachmentDownloadsEnabled
        ? Container(
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? const Color(0xFF3E4559) : const Color(0xFF232327),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2B2B30)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, color: OsColors.dim),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    '${currentAttachment.displayName}\n没有下载附件的权限',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: OsColors.muted, height: 1.35),
                  ),
                ),
              ],
            ),
          )
        : imageAttachment
        ? ImageAttachmentPreview(
            key: ValueKey(currentAttachment.fileId),
            attachment: currentAttachment,
            loadPreview: loadImagePreview,
            onOpen: () => onOpen(currentAttachment),
            onSaveAs: () => onSaveAs(currentAttachment),
            showDetails: false,
          )
        : audioAttachment
        ? AudioAttachmentCard(
            attachment: currentAttachment,
            metadataFuture: loadAudioMetadata(currentAttachment),
            active: activeAudioFileId == currentAttachment.fileId,
            loading: audioLoadingFileId == currentAttachment.fileId,
            playing:
                activeAudioFileId == currentAttachment.fileId && audioPlaying,
            position: activeAudioFileId == currentAttachment.fileId
                ? audioPosition
                : Duration.zero,
            duration: activeAudioFileId == currentAttachment.fileId
                ? audioDuration
                : Duration.zero,
            transferTask: downloadTask,
            onToggle: () => onToggleAudio(currentAttachment),
            onSeek: onSeekAudio,
            onSaveAs: () => onSaveAs(currentAttachment),
            onCancel: () => onCancelDownload(currentAttachment),
          )
        : Container(
            constraints: BoxConstraints(
              maxWidth: linkPreviewFallback == null ? 520 : 430,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: mine ? const Color(0xFF3E4559) : const Color(0xFF232327),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2B2B30)),
            ),
            child: currentAttachment == null
                ? Column(
                    crossAxisAlignment: mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MessageBodyText(
                        body: body,
                        mine: mine,
                        onOpenLink: onOpenLink,
                        messageActionLabel: messageActionLabel,
                        onMessageAction: onMessageAction,
                      ),
                      LinkPreviewSlot(
                        fallbackPreview: linkPreviewFallback,
                        previewFuture: linkPreviewFuture,
                        onOpen: onOpenLink,
                      ),
                    ],
                  )
                : AttachmentBubble(
                    attachment: currentAttachment,
                    ensureCached: ensureCached,
                    onOpen: () => onOpen(currentAttachment),
                    onSaveAs: () => onSaveAs(currentAttachment),
                    transferTask: downloadTask,
                    onCancel: () => onCancelDownload(currentAttachment),
                  ),
          );

    final bubbleContextMenu = currentAttachment == null
        ? (Offset position) =>
              unawaited(_showTextBubbleContextMenu(context, position))
        : onMessageContextMenu;
    final bubble = Flexible(
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 5),
          GestureDetector(
            key: const ValueKey('chat-message-bubble-context-target'),
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: bubbleContextMenu == null
                ? null
                : (details) => bubbleContextMenu(details.globalPosition),
            child: content,
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: mine
            ? [bubble, const SizedBox(width: 12), avatar]
            : [avatar, const SizedBox(width: 12), bubble],
      ),
    );
  }
}

class MessageBodyText extends StatelessWidget {
  const MessageBodyText({
    super.key,
    required this.body,
    required this.mine,
    required this.onOpenLink,
    this.messageActionLabel,
    this.onMessageAction,
  });

  final String body;
  final bool mine;
  final Future<void> Function(String url) onOpenLink;
  final String? messageActionLabel;
  final VoidCallback? onMessageAction;

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      color: OsColors.text,
      fontSize: 14,
      height: 1.28,
    );
    const linkStyle = TextStyle(
      color: Color(0xFFB9D1FF),
      decoration: TextDecoration.underline,
      decorationColor: Color(0xFFB9D1FF),
      fontSize: 14,
      height: 1.28,
    );
    final matches = previewableUrlMatches(body).toList(growable: false);
    if (matches.isEmpty) {
      return _MessagePlainText(
        body,
        textAlign: mine ? TextAlign.right : TextAlign.left,
        style: baseStyle,
        messageActionLabel: messageActionLabel,
        onMessageAction: onMessageAction,
      );
    }

    var offset = 0;
    final spans = <InlineSpan>[];
    for (final match in matches) {
      if (match.start > offset) {
        spans.add(TextSpan(text: body.substring(offset, match.start)));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(onOpenLink(match.url)),
              child: Text(match.text, style: linkStyle),
            ),
          ),
        ),
      );
      offset = match.end;
    }
    if (offset < body.length) {
      spans.add(TextSpan(text: body.substring(offset)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      textAlign: mine ? TextAlign.right : TextAlign.left,
    );
  }
}

class _MessagePlainText extends StatefulWidget {
  const _MessagePlainText(
    this.text, {
    required this.textAlign,
    required this.style,
    this.messageActionLabel,
    this.onMessageAction,
  });

  final String text;
  final TextAlign textAlign;
  final TextStyle style;
  final String? messageActionLabel;
  final VoidCallback? onMessageAction;

  @override
  State<_MessagePlainText> createState() => _MessagePlainTextState();
}

class _MessagePlainTextState extends State<_MessagePlainText> {
  late final TextEditingController _controller;
  TextSelection? _selectionBeforeSecondaryTap;
  var _restoringSelection = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text)
      ..addListener(_restoreSelectionAfterSecondaryTap);
  }

  @override
  void didUpdateWidget(covariant _MessagePlainText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.removeListener(_restoreSelectionAfterSecondaryTap);
    _controller.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons == kSecondaryMouseButton) {
      _selectionBeforeSecondaryTap = _controller.selection;
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_selectionBeforeSecondaryTap == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _selectionBeforeSecondaryTap = null;
    });
  }

  void _restoreSelectionAfterSecondaryTap() {
    final previous = _selectionBeforeSecondaryTap;
    if (previous != null &&
        !_restoringSelection &&
        _controller.selection != previous) {
      _restoringSelection = true;
      _controller.selection = previous;
      _restoringSelection = false;
    }
  }

  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final nativeCopy = editableTextState.contextMenuButtonItems
        .where((item) => item.type == ContextMenuButtonType.copy)
        .toList(growable: false);
    final items = <ContextMenuButtonItem>[
      if (nativeCopy.isNotEmpty)
        ...osLocalizedContextMenuItems(nativeCopy)
      else
        ContextMenuButtonItem(
          onPressed: () {
            editableTextState.hideToolbar();
            unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
          },
          type: ContextMenuButtonType.copy,
          label: '复制',
        ),
      if (widget.messageActionLabel != null && widget.onMessageAction != null)
        ContextMenuButtonItem(
          onPressed: () {
            editableTextState.hideToolbar();
            widget.onMessageAction!();
          },
          label: widget.messageActionLabel,
        ),
    ];
    return OsCompactTextSelectionToolbar(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (useMobileWebLayout(
      isWeb: kIsWeb,
      width: MediaQuery.sizeOf(context).width,
    )) {
      return SelectableText(
        widget.text,
        textAlign: widget.textAlign,
        style: widget.style,
        contextMenuBuilder: _buildContextMenu,
      );
    }
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: IntrinsicWidth(
        child: TextField(
          controller: _controller,
          readOnly: true,
          showCursor: false,
          maxLines: null,
          textAlign: widget.textAlign,
          style: widget.style,
          decoration: null,
          contextMenuBuilder: _buildContextMenu,
        ),
      ),
    );
  }
}

class LinkPreviewSlot extends StatelessWidget {
  const LinkPreviewSlot({
    super.key,
    required this.fallbackPreview,
    required this.previewFuture,
    required this.onOpen,
  });

  final LinkPreview? fallbackPreview;
  final Future<LinkPreview?>? previewFuture;
  final Future<void> Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    final future = previewFuture;
    final fallback = fallbackPreview;
    if (future == null && fallback == null) return const SizedBox.shrink();
    return FutureBuilder<LinkPreview?>(
      future: future,
      builder: (context, snapshot) {
        final preview = snapshot.connectionState == ConnectionState.done
            ? snapshot.data ?? fallback
            : fallback;
        if (snapshot.hasError || preview == null || !preview.hasContent) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: LinkPreviewCard(
            preview: preview,
            onTap: () => unawaited(onOpen(preview.url)),
          ),
        );
      },
    );
  }
}

class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({
    super.key,
    required this.preview,
    required this.onTap,
  });

  final LinkPreview preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final imageUrl = preview.imageUrl.trim();
    final title = linkPreviewTitle(preview);
    final description = linkPreviewDescription(preview);
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        margin: const EdgeInsets.only(top: 7),
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: const Color(0xFF4A536B),
          borderRadius: BorderRadius.circular(7),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: imageUrl.isNotEmpty ? 88 : 68,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: OsColors.blurple,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OsColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          height: 1.18,
                        ),
                      ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: imageUrl.isNotEmpty ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFD6DBE8),
                          fontSize: 12.5,
                          height: 1.22,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (imageUrl.isNotEmpty) ...[
              const SizedBox(width: 8),
              LinkPreviewImage(url: imageUrl),
            ],
          ],
        ),
      ),
    );
  }
}

class LinkPreviewImage extends StatefulWidget {
  const LinkPreviewImage({super.key, required this.url});

  final String url;

  @override
  State<LinkPreviewImage> createState() => _LinkPreviewImageState();
}

class _LinkPreviewImageState extends State<LinkPreviewImage> {
  bool failed = false;

  @override
  void didUpdateWidget(LinkPreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      failed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (failed) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 88,
        height: 88,
        child: Image.network(
          widget.url,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => failed = true);
            });
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    required this.mine,
    this.avatarFile,
    this.avatarRevision = 0,
    this.avatarUri,
    this.avatarToken,
  });

  final String name;
  final bool mine;
  final File? avatarFile;
  final int avatarRevision;
  final Uri? avatarUri;
  final String? avatarToken;

  @override
  Widget build(BuildContext context) {
    return OsUserAvatar(
      displayName: name,
      size: 36,
      avatarFile: avatarFile,
      avatarRevision: avatarRevision,
      avatarUri: avatarUri,
      avatarToken: avatarToken,
      backgroundColor: mine ? OsColors.blurple : const Color(0xFFA55CD2),
    );
  }
}

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.enabled,
    this.readOnly = false,
    this.addEnabled,
    this.hintText,
    required this.disabledHintText,
    required this.onAdd,
    required this.onSend,
    this.onPasteImage,
    this.clipboardImageReader,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool readOnly;
  final bool? addEnabled;
  final String? hintText;
  final String disabledHintText;
  final VoidCallback onAdd;
  final VoidCallback onSend;
  final Future<void> Function(ClipboardImageData image)? onPasteImage;
  final Future<ClipboardImageData?> Function()? clipboardImageReader;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _focusNode = FocusNode();
  late final ClipboardImagePasteListener _pasteListener;
  bool _pasteInFlight = false;

  bool get _canPasteImage =>
      widget.enabled &&
      !widget.readOnly &&
      (widget.addEnabled ?? widget.enabled) &&
      widget.onPasteImage != null;

  @override
  void initState() {
    super.initState();
    _pasteListener = ClipboardImagePasteListener(
      enabled: () => _canPasteImage && _focusNode.hasFocus,
      onPaste: _handleImagePaste,
    );
  }

  Future<void> _handleImagePaste(ClipboardImageData image) async {
    if (!_canPasteImage || _pasteInFlight) return;
    _pasteInFlight = true;
    try {
      await widget.onPasteImage!(image);
    } finally {
      _pasteInFlight = false;
    }
  }

  Future<bool> _readAndPasteImage() async {
    if (!_canPasteImage || _pasteInFlight) return _pasteInFlight;
    final image = await (widget.clipboardImageReader ?? readClipboardImage)();
    if (image == null) return false;
    await _handleImagePaste(image);
    return true;
  }

  Future<void> _pasteFromShortcut() async {
    if (await _readAndPasteImage()) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || !_canPasteImage || text == null || text.isEmpty) return;
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    widget.controller.value = value.replaced(selection, text);
  }

  KeyEventResult _handlePasteShortcut(FocusNode _, KeyEvent event) {
    if (clipboardImagePasteEventsSupported ||
        !_canPasteImage ||
        event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifierPressed = Theme.of(context).platform == TargetPlatform.macOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    final pastePressed =
        event.logicalKey == LogicalKeyboardKey.keyV && modifierPressed;
    final insertPressed =
        event.logicalKey == LogicalKeyboardKey.insert &&
        keyboard.isShiftPressed;
    if (!pastePressed && !insertPressed) return KeyEventResult.ignored;
    unawaited(_pasteFromShortcut());
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final textField = TextField(
      focusNode: _focusNode,
      controller: widget.controller,
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      contextMenuBuilder: (context, editableTextState) =>
          osEditableTextContextMenuBuilder(
            context,
            editableTextState,
            onPaste: _canPasteImage ? _readAndPasteImage : null,
          ),
      minLines: 1,
      maxLines: 4,
      textInputAction: TextInputAction.send,
      onEditingComplete: () {},
      onSubmitted: widget.readOnly ? null : (_) => widget.onSend(),
      decoration: InputDecoration(
        hintText: widget.enabled ? widget.hintText : widget.disabledHintText,
        filled: true,
        fillColor: const Color(0xFF232327),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2B2B30)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2B2B30)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: OsColors.rowHover),
        ),
        prefixIcon: IconButton(
          tooltip: '添加文件',
          onPressed: (widget.addEnabled ?? widget.enabled)
              ? widget.onAdd
              : null,
          icon: const Icon(Icons.add_circle, size: 22),
        ),
        suffixIcon: IconButton(
          tooltip: '发送',
          onPressed: widget.enabled && !widget.readOnly ? widget.onSend : null,
          icon: const Icon(Icons.send, size: 20),
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: OsColors.divider)),
      ),
      child: Focus(onKeyEvent: _handlePasteShortcut, child: textField),
    );
  }

  @override
  void dispose() {
    _pasteListener.dispose();
    _focusNode.dispose();
    super.dispose();
  }
}

bool startsNewLocalDay(DateTime? value, DateTime? previous) {
  if (value == null || previous == null) return false;
  final local = value.toLocal();
  final previousLocal = previous.toLocal();
  return local.year != previousLocal.year ||
      local.month != previousLocal.month ||
      local.day != previousLocal.day;
}

String localDateLabel(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}年${two(local.month)}月${two(local.day)}日';
}

class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, color: OsColors.icon, size: 38),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: OsColors.muted)),
        ],
      ),
    );
  }
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF5C2B2B),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              message,
              style: const TextStyle(color: Color(0xFFFFD7D7)),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 12),
            OutlinedButton.icon(
              key: const ValueKey('error-box-action'),
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFFE6E6),
                side: const BorderSide(color: Color(0x99FFD7D7)),
                backgroundColor: const Color(0x33231919),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              icon: const Icon(Icons.settings_outlined, size: 17),
              label: Text(
                actionLabel!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class NewMessagesPill extends StatelessWidget {
  const NewMessagesPill({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2C2F39),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: OsColors.blurple),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Text(
            '有 $count 条新消息 ↓',
            style: const TextStyle(
              color: Color(0xFFC9D2FF),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}
