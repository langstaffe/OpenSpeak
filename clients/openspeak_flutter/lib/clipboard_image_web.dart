import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:web/web.dart' as web;

const clipboardImagePasteEventsSupported = true;

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
  ClipboardImagePasteListener({required this.enabled, required this.onPaste}) {
    _listener = ((web.Event rawEvent) {
      if (!enabled()) return;
      final event = rawEvent as web.ClipboardEvent;
      final items = event.clipboardData?.items;
      if (items == null) return;
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        if (item.kind != 'file' || !item.type.startsWith('image/')) continue;
        final file = item.getAsFile();
        if (file == null) continue;
        event.preventDefault();
        event.stopImmediatePropagation();
        unawaited(_read(file, item.type));
        return;
      }
    }).toJS;
    web.document.addEventListener('paste', _listener, true.toJS);
  }

  final bool Function() enabled;
  final Future<void> Function(Uint8List bytes, String mimeType) onPaste;
  late final web.EventListener _listener;

  Future<void> _read(web.File file, String mimeType) async {
    try {
      final buffer = await file.arrayBuffer().toDart;
      final bytes = buffer.toDart.asUint8List();
      if (bytes.isNotEmpty) await onPaste(bytes, mimeType);
    } catch (error) {
      debugPrint('Clipboard paste event read failed: $error');
    }
  }

  void dispose() =>
      web.document.removeEventListener('paste', _listener, true.toJS);
}
