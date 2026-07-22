import 'dart:typed_data';

bool browserSupportsWebRtc() => true;

String? readBrowserSessionValue(String key) => null;

void writeBrowserSessionValue(String key, String value) {}

void removeBrowserSessionValue(String key) {}

void downloadBrowserBytes(Uint8List bytes, String name, String contentType) {
  throw UnsupportedError('Browser downloads are unavailable');
}

String createBrowserObjectUrl(Uint8List bytes, String contentType) {
  throw UnsupportedError('Browser object URLs are unavailable');
}

void revokeBrowserObjectUrl(String url) {}

void openBrowserUrl(String url) {
  throw UnsupportedError('Browser navigation is unavailable');
}
