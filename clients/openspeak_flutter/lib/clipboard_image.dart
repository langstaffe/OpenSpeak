import 'dart:typed_data';

import 'clipboard_image_io.dart'
    if (dart.library.js_interop) 'clipboard_image_web.dart'
    as platform;

class ClipboardImageData {
  const ClipboardImageData(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;
}

const clipboardImagePasteEventsSupported =
    platform.clipboardImagePasteEventsSupported;

Future<ClipboardImageData?> readClipboardImage() async {
  final image = await platform.readClipboardImage();
  return image == null ? null : ClipboardImageData(image.bytes, image.mimeType);
}

class ClipboardImagePasteListener {
  ClipboardImagePasteListener({
    required bool Function() enabled,
    required Future<void> Function(ClipboardImageData image) onPaste,
  }) : _delegate = platform.ClipboardImagePasteListener(
         enabled: enabled,
         onPaste: (bytes, mimeType) =>
             onPaste(ClipboardImageData(bytes, mimeType)),
       );

  final platform.ClipboardImagePasteListener _delegate;

  void dispose() => _delegate.dispose();
}

String clipboardImageFileExtension(String mimeType) =>
    switch (mimeType.toLowerCase()) {
      'image/jpeg' || 'image/jpg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      'image/heic' => 'heic',
      'image/heif' => 'heif',
      'image/svg+xml' => 'svg',
      _ => 'png',
    };
