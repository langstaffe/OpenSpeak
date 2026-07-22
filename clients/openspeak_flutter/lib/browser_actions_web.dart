// dart:html is used only by the JavaScript Web target. Keeping it behind a
// conditional export prevents browser APIs from leaking into desktop builds.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:typed_data';

@JS('RTCPeerConnection')
external JSFunction? get _rtcPeerConnection;

bool browserSupportsWebRtc() => _rtcPeerConnection != null;

String? readBrowserSessionValue(String key) {
  try {
    return html.window.sessionStorage[key];
  } catch (_) {
    return null;
  }
}

void writeBrowserSessionValue(String key, String value) {
  try {
    html.window.sessionStorage[key] = value;
  } catch (_) {
    // Private browsing policies may disable storage; login still works.
  }
}

void removeBrowserSessionValue(String key) {
  try {
    html.window.sessionStorage.remove(key);
  } catch (_) {
    // Nothing to clear when storage is unavailable.
  }
}

void downloadBrowserBytes(Uint8List bytes, String name, String contentType) {
  final url = createBrowserObjectUrl(bytes, contentType);
  final anchor = html.AnchorElement(href: url)
    ..download = name
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 1),
    () => revokeBrowserObjectUrl(url),
  );
}

String createBrowserObjectUrl(Uint8List bytes, String contentType) =>
    html.Url.createObjectUrlFromBlob(html.Blob([bytes], contentType));

void revokeBrowserObjectUrl(String url) => html.Url.revokeObjectUrl(url);

void openBrowserUrl(String url) {
  html.window.open(url, '_blank', 'noopener,noreferrer');
}
