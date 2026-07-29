import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';

const clipboardImagePasteEventsSupported = false;

Future<({Uint8List bytes, String mimeType})?> readClipboardImage() async {
  try {
    final bytes = await Pasteboard.image;
    return bytes == null || bytes.isEmpty
        ? null
        : (bytes: bytes, mimeType: 'image/png');
  } catch (error) {
    debugPrint('Clipboard image read failed: $error');
    return null;
  }
}

class ClipboardImagePasteListener {
  const ClipboardImagePasteListener({
    required bool Function() enabled,
    required Future<void> Function(Uint8List bytes, String mimeType) onPaste,
  });

  void dispose() {}
}
