import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/client_link_preview.dart';

void main() {
  test('Web link preview fetch parses a same-origin response', () async {
    final preview = await fetchClientLinkPreview(Uri.base.toString());

    expect(preview.url, Uri.base.toString());
    expect(preview.title, isNot(Uri.base.host));
  }, skip: !kIsWeb);
}
