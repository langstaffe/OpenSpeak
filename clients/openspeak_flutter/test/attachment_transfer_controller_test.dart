import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/attachment_transfer_controller.dart';

void main() {
  test(
    'local attachment state registers, validates, and removes sources',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openspeak_attachment_transfer_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/source').writeAsBytes([1, 2]);
      final controller = AttachmentTransferController();

      controller.registerLocalSource('valid', file, expectedSizeBytes: 2);
      controller.pendingLocalUploads.add('valid');
      await Future<void>.delayed(Duration.zero);
      expect(controller.localSources['valid'], file);
      expect(controller.pendingLocalUploads, contains('valid'));

      controller.removeLocalUpload('valid');
      expect(controller.localSources, isNot(contains('valid')));
      expect(controller.pendingLocalUploads, isNot(contains('valid')));

      final invalidated = Completer<void>();
      controller.registerLocalSource(
        'invalid',
        file,
        expectedSizeBytes: 3,
        onInvalid: invalidated.complete,
      );
      await invalidated.future;
      expect(controller.localSources, isNot(contains('invalid')));
    },
  );
}
