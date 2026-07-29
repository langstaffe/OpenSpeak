import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
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

  test('completed temporary uploads remove their source file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openspeak_temporary_upload_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/clipboard.png',
    ).writeAsBytes([1, 2, 3]);
    final task = TransferTask.upload(
      file: XFile(file.path),
      direct: false,
      targetId: 'channel',
      image: true,
      temporary: true,
    );
    final controller = AttachmentTransferController()..uploads.add(task);

    await controller.processUploads(upload: (_) async {}, onChanged: () {});

    expect(await file.exists(), isFalse);
  });
}
