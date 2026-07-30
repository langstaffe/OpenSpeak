import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'attachment_transfer_controller.dart';
import 'audio_attachment_metadata.dart';
import 'os_theme.dart';
import 'responsive_layout.dart';
import 'smooth_scroll.dart';

class AudioSeekSlider extends StatefulWidget {
  const AudioSeekSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration position) onSeek;

  @override
  State<AudioSeekSlider> createState() => _AudioSeekSliderState();
}

class _AudioSeekSliderState extends State<AudioSeekSlider> {
  double? dragValue;
  var dragGeneration = 0;

  Future<void> commit(double value, int generation) async {
    try {
      await widget.onSeek(Duration(milliseconds: value.round()));
    } finally {
      if (mounted && generation == dragGeneration) {
        setState(() => dragValue = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maximum = widget.duration.inMilliseconds <= 0
        ? 1.0
        : widget.duration.inMilliseconds.toDouble();
    final value = (dragValue ?? widget.position.inMilliseconds.toDouble())
        .clamp(0.0, maximum);
    final enabled = widget.duration > Duration.zero;
    return Slider(
      min: 0,
      max: maximum,
      value: value,
      onChangeStart: enabled
          ? (value) {
              dragGeneration += 1;
              setState(() => dragValue = value);
            }
          : null,
      onChanged: enabled ? (value) => setState(() => dragValue = value) : null,
      onChangeEnd: enabled
          ? (value) => unawaited(commit(value, dragGeneration))
          : null,
    );
  }
}

class AudioNowPlayingControl extends StatelessWidget {
  const AudioNowPlayingControl({
    super.key,
    required this.attachment,
    required this.metadataFuture,
    required this.loading,
    required this.playing,
    required this.position,
    required this.duration,
    required this.compact,
    required this.onToggle,
  });

  final ChatAttachment attachment;
  final Future<AudioAttachmentMetadata> metadataFuture;
  final bool loading;
  final bool playing;
  final Duration position;
  final Duration duration;
  final bool compact;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final progress = duration <= Duration.zero
        ? 0.0
        : (position.inMicroseconds / duration.inMicroseconds)
              .clamp(0.0, 1.0)
              .toDouble();
    return SizedBox(
      width: compact ? 156 : 220,
      height: 42,
      child: FutureBuilder<AudioAttachmentMetadata>(
        future: metadataFuture,
        builder: (context, snapshot) {
          final metadata =
              snapshot.data ??
              AudioAttachmentMetadata(title: attachment.displayName);
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metadata.title.trim().isEmpty
                          ? attachment.displayName
                          : metadata.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      metadata.artist.trim().isEmpty
                          ? '未知艺术家'
                          : metadata.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: OsColors.dim, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SizedBox.square(
                dimension: 42,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: RotatedBox(
                        quarterTurns: 2,
                        child: CircularProgressIndicator(
                          key: const ValueKey('audio-now-playing-progress'),
                          value: progress,
                          strokeWidth: 2,
                          color: Colors.white,
                          backgroundColor: OsColors.icon,
                          semanticsLabel: '播放进度',
                          semanticsValue: '${(progress * 100).round()}%',
                        ),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: playing ? '暂停' : '播放',
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(36),
                        minimumSize: const Size.square(36),
                        padding: EdgeInsets.zero,
                        backgroundColor: OsColors.blurple,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: loading ? null : onToggle,
                      icon: loading
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                              size: 22,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class AudioAttachmentCard extends StatelessWidget {
  const AudioAttachmentCard({
    super.key,
    required this.attachment,
    required this.metadataFuture,
    required this.active,
    required this.loading,
    required this.playing,
    required this.position,
    required this.duration,
    required this.transferTask,
    required this.onToggle,
    required this.onSeek,
    required this.onSaveAs,
    required this.onCancel,
  });

  final ChatAttachment attachment;
  final Future<AudioAttachmentMetadata> metadataFuture;
  final bool active;
  final bool loading;
  final bool playing;
  final Duration position;
  final Duration duration;
  final TransferTask? transferTask;
  final VoidCallback onToggle;
  final Future<void> Function(Duration position) onSeek;
  final VoidCallback onSaveAs;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final task = transferTask;
    if (attachment.expired) {
      return const SizedBox(
        width: 320,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, color: OsColors.danger, size: 24),
            SizedBox(width: 10),
            Text('文件已过期', style: TextStyle(color: OsColors.muted)),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 430),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF232327),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2B2B30)),
        ),
        child: FutureBuilder<AudioAttachmentMetadata>(
          future: metadataFuture,
          builder: (context, snapshot) {
            final metadata =
                snapshot.data ??
                AudioAttachmentMetadata(title: attachment.displayName);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    AudioCover(bytes: metadata.coverBytes),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            metadata.title.trim().isEmpty
                                ? attachment.displayName
                                : metadata.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.text,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            metadata.artist.trim().isEmpty
                                ? '未知艺术家'
                                : metadata.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.dim,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            readableBytes(attachment.sizeBytes),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.dim,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '另存为',
                      onPressed: onSaveAs,
                      icon: const Icon(Icons.download, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    IconButton.filled(
                      tooltip: playing ? '暂停' : '播放',
                      style: IconButton.styleFrom(
                        backgroundColor: OsColors.blurple,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: loading ? null : onToggle,
                      icon: loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatDuration(active ? position : Duration.zero),
                      style: const TextStyle(
                        color: OsColors.muted,
                        fontSize: 12,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                        ),
                        child: AudioSeekSlider(
                          position: active ? position : Duration.zero,
                          duration: active ? duration : Duration.zero,
                          onSeek: onSeek,
                        ),
                      ),
                    ),
                    Text(
                      formatDuration(duration),
                      style: const TextStyle(
                        color: OsColors.muted,
                        fontSize: 12,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (task != null) ...[
                  const SizedBox(height: 6),
                  TransferInlineProgress(task: task),
                  if (task.status == TransferStatus.running)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('取消'),
                      ),
                    )
                  else if (task.status == TransferStatus.failed)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: onSaveAs,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重试'),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class AudioCover extends StatelessWidget {
  const AudioCover({super.key, required this.bytes});

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final coverBytes = bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 58,
        height: 58,
        color: const Color(0xFF31343A),
        child: coverBytes == null
            ? const Icon(Icons.music_note, color: OsColors.muted, size: 30)
            : Image.memory(
                coverBytes,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.music_note, color: OsColors.muted),
              ),
      ),
    );
  }
}

class AttachmentBubble extends StatelessWidget {
  const AttachmentBubble({
    super.key,
    required this.attachment,
    required this.ensureCached,
    required this.onOpen,
    required this.onSaveAs,
    required this.transferTask,
    required this.onCancel,
  });

  final ChatAttachment attachment;
  final Future<File> Function(ChatAttachment attachment) ensureCached;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;
  final TransferTask? transferTask;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final expiresAt = attachment.expiresAt;
    final task = transferTask;
    if (attachment.expired) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 260, maxWidth: 360),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, color: OsColors.danger, size: 24),
            SizedBox(width: 10),
            Text(
              '文件已过期',
              style: TextStyle(
                color: OsColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 360),
      child: InkWell(
        onTap: onOpen,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF31343A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.insert_drive_file,
                color: OsColors.muted,
                size: 24,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: OsColors.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      '文件',
                      readableBytes(attachment.sizeBytes),
                      if (attachment.direct && expiresAt != null)
                        '${shortTime(expiresAt)} 过期',
                    ].where((item) => item.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: OsColors.dim, fontSize: 12),
                  ),
                  if (task != null) ...[
                    const SizedBox(height: 6),
                    TransferInlineProgress(task: task),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (task?.status == TransferStatus.failed)
              IconButton(
                tooltip: '重试',
                onPressed: onOpen,
                icon: const Icon(Icons.refresh, size: 20),
              )
            else if (task?.status == TransferStatus.running)
              IconButton(
                tooltip: '取消',
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 20),
              )
            else
              IconButton(
                tooltip: '另存为',
                onPressed: onSaveAs,
                icon: const Icon(Icons.download, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

class ImageAttachmentPreview extends StatefulWidget {
  const ImageAttachmentPreview({
    super.key,
    required this.attachment,
    required this.loadPreview,
    required this.onOpen,
    required this.onSaveAs,
    this.showDetails = true,
  });

  final ChatAttachment attachment;
  final Future<CachedImagePreview> Function(ChatAttachment attachment)
  loadPreview;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;
  final bool showDetails;

  @override
  State<ImageAttachmentPreview> createState() => _ImageAttachmentPreviewState();
}

const _maxImagePreviewWidth = 420.0;
const _maxImagePreviewHeight = 360.0;

class CachedImagePreview {
  const CachedImagePreview({this.file, this.bytes, required this.size});

  final File? file;
  final Uint8List? bytes;
  final Size size;
}

class ImageLightbox extends StatelessWidget {
  const ImageLightbox({
    super.key,
    required this.preview,
    required this.onDownload,
    required this.onClose,
  });

  final Future<CachedImagePreview> preview;
  final VoidCallback onDownload;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: FutureBuilder<CachedImagePreview>(
              future: preview,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                final bytes = snapshot.data?.bytes;
                if (snapshot.hasError || bytes == null) {
                  return const Center(
                    child: Text(
                      '图片预览失败',
                      style: TextStyle(color: OsColors.muted),
                    ),
                  );
                }
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: SizedBox.expand(
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => const Center(
                        child: Text(
                          '图片预览失败',
                          style: TextStyle(color: OsColors.muted),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xCC1F2025),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0x663B3D45)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '下载',
                    onPressed: onDownload,
                    icon: const Icon(Icons.download, color: OsColors.text),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    icon: const Icon(Icons.close, color: OsColors.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<Size> readImageSize(File file) async {
  return readImageSizeBytes(await file.readAsBytes());
}

Future<Size> readImageSizeBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final size = Size(image.width.toDouble(), image.height.toDouble());
  image.dispose();
  return size;
}

Size _fitImageSize({
  required Size source,
  required double maxWidth,
  required double maxHeight,
}) {
  if (maxWidth <= 0 || maxHeight <= 0) {
    return Size.zero;
  }
  if (source.width <= 0 || source.height <= 0) {
    return Size(maxWidth, maxHeight);
  }
  final aspectRatio = source.width / source.height;
  var width = source.width;
  var height = source.height;

  if (width > maxWidth) {
    width = maxWidth;
    height = width / aspectRatio;
  }
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspectRatio;
  }
  return Size(width, height);
}

class _ImageAttachmentPreviewState extends State<ImageAttachmentPreview> {
  late Future<CachedImagePreview> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = _loadImage();
  }

  @override
  void didUpdateWidget(ImageAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.fileId != widget.attachment.fileId) {
      _imageFuture = _loadImage();
    }
  }

  Future<CachedImagePreview> _loadImage() async {
    return widget.loadPreview(widget.attachment);
  }

  @override
  Widget build(BuildContext context) {
    final expiresAt = widget.attachment.expiresAt;
    if (widget.attachment.expired) {
      return const SizedBox(
        width: 260,
        height: 120,
        child: Center(
          child: Text('文件已过期', style: TextStyle(color: OsColors.muted)),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showDetails) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.attachment.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: OsColors.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '另存为',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onSaveAs,
                  icon: const Icon(Icons.download, size: 18),
                ),
              ],
            ),
            Text(
              [
                '图片',
                readableBytes(widget.attachment.sizeBytes),
                if (widget.attachment.direct && expiresAt != null)
                  '${shortTime(expiresAt)} 过期',
              ].where((item) => item.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: OsColors.dim, fontSize: 12),
            ),
            const SizedBox(height: 8),
          ],
          FutureBuilder<CachedImagePreview>(
            future: _imageFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  width: 260,
                  height: 150,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return ImagePreviewFailure(onSaveAs: widget.onSaveAs);
              }
              final image = snapshot.data!;
              return LayoutBuilder(
                builder: (context, constraints) {
                  final maxWidth = constraints.maxWidth.isFinite
                      ? constraints.maxWidth.clamp(0.0, _maxImagePreviewWidth)
                      : _maxImagePreviewWidth;
                  final displaySize = _fitImageSize(
                    source: image.size,
                    maxWidth: maxWidth,
                    maxHeight: _maxImagePreviewHeight,
                  );
                  final cacheWidth = imagePreviewCacheWidth(
                    isWeb: kIsWeb,
                    viewportWidth: MediaQuery.sizeOf(context).width,
                    sourceWidth: image.size.width,
                    displayWidth: displaySize.width,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  );
                  return Stack(
                    children: [
                      InkWell(
                        onTap: widget.onOpen,
                        mouseCursor: SystemMouseCursors.click,
                        borderRadius: BorderRadius.circular(8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          clipBehavior: Clip.antiAlias,
                          child: SizedBox(
                            width: displaySize.width,
                            height: displaySize.height,
                            child: image.bytes != null
                                ? Image.memory(
                                    image.bytes!,
                                    width: displaySize.width,
                                    height: displaySize.height,
                                    cacheWidth: cacheWidth,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                    errorBuilder: (_, _, _) =>
                                        ImagePreviewFailure(
                                          onSaveAs: widget.onSaveAs,
                                        ),
                                  )
                                : Image.file(
                                    image.file!,
                                    width: displaySize.width,
                                    height: displaySize.height,
                                    cacheWidth: cacheWidth,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                    errorBuilder: (_, _, _) =>
                                        ImagePreviewFailure(
                                          onSaveAs: widget.onSaveAs,
                                        ),
                                  ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xCC1F2025),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: const Color(0x663B3D45)),
                          ),
                          child: IconButton(
                            tooltip: '另存为',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 34,
                              height: 34,
                            ),
                            onPressed: widget.onSaveAs,
                            icon: const Icon(
                              Icons.download,
                              size: 19,
                              color: OsColors.text,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class ImagePreviewFailure extends StatelessWidget {
  const ImagePreviewFailure({super.key, required this.onSaveAs});

  final VoidCallback onSaveAs;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      height: 120,
      decoration: BoxDecoration(
        color: const Color(0xFF31343A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.broken_image, color: OsColors.dim, size: 26),
          const SizedBox(height: 8),
          const Text('图片预览失败', style: TextStyle(color: OsColors.muted)),
          TextButton.icon(
            onPressed: onSaveAs,
            icon: const Icon(Icons.download, size: 16),
            label: const Text('另存为'),
          ),
        ],
      ),
    );
  }
}

class UploadQueuePanel extends StatelessWidget {
  const UploadQueuePanel({
    super.key,
    required this.tasks,
    required this.onCancel,
    required this.onRetry,
  });

  final List<TransferTask> tasks;
  final ValueChanged<TransferTask> onCancel;
  final ValueChanged<TransferTask> onRetry;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SmoothSingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final task in tasks)
              TransferProgressPanel(
                task: task,
                onCancel: () => onCancel(task),
                onRetry: () => onRetry(task),
              ),
          ],
        ),
      ),
    );
  }
}

class TransferProgressPanel extends StatelessWidget {
  const TransferProgressPanel({
    super.key,
    required this.task,
    required this.onCancel,
    required this.onRetry,
  });

  final TransferTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = task.status == TransferStatus.failed;
    final queued = task.status == TransferStatus.queued;
    final finishing =
        !failed &&
        task.totalBytes > 0 &&
        task.transferredBytes >= task.totalBytes;
    final subtitle = failed
        ? task.error ?? '上传失败'
        : queued
        ? '等待上传'
        : finishing
        ? '正在完成上传'
        : [
            '正在上传',
            if (task.totalBytes > 0)
              '${readableBytes(task.transferredBytes)} / ${readableBytes(task.totalBytes)}',
          ].join(' · ');
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF232327),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2B2B30)),
      ),
      child: Row(
        children: [
          Icon(
            task.image ? Icons.image : Icons.insert_drive_file,
            color: failed ? OsColors.danger : OsColors.green,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  task.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: OsColors.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: OsColors.dim, fontSize: 12),
                ),
                if (!failed && !queued) ...[
                  const SizedBox(height: 6),
                  TransferProgressBar(
                    value: task.progress,
                    color: OsColors.green,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (failed)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            )
          else
            IconButton(
              tooltip: '取消',
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}

class TransferInlineProgress extends StatelessWidget {
  const TransferInlineProgress({super.key, required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final failed = task.status == TransferStatus.failed;
    final progress = task.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TransferProgressBar(
          value: failed ? 1 : progress,
          color: failed ? OsColors.danger : OsColors.green,
        ),
        const SizedBox(height: 3),
        Text(
          failed
              ? '下载失败，可重试'
              : task.totalBytes > 0
              ? '下载中 ${readableBytes(task.transferredBytes)} / ${readableBytes(task.totalBytes)}'
              : '下载中',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: failed ? OsColors.danger : OsColors.dim,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class TransferProgressBar extends StatelessWidget {
  const TransferProgressBar({
    super.key,
    required this.value,
    required this.color,
  });

  final double? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final clamped = value?.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 4,
        color: const Color(0xFF34373D),
        child: clamped == null
            ? const LinearProgressIndicator(
                minHeight: 4,
                backgroundColor: Color(0xFF34373D),
                color: OsColors.green,
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: clamped,
                  child: ColoredBox(
                    color: color,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
      ),
    );
  }
}

String formatDuration(Duration value) {
  if (value.isNegative) value = Duration.zero;
  final totalSeconds = value.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '$minutes:${two(seconds)}';
}

String shortTime(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

class DropUploadOverlay extends StatelessWidget {
  const DropUploadOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xAA202225),
        border: Border.all(color: OsColors.green, width: 2),
      ),
      child: const Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(0xFF232327),
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file, color: OsColors.green, size: 26),
                SizedBox(width: 10),
                Text(
                  '松开以上传文件',
                  style: TextStyle(
                    color: OsColors.text,
                    fontSize: 16,
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
