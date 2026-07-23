import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/main.dart';

void main() {
  test(
    'browser audio unlock runs before asynchronous attachment loading',
    () async {
      final loadResult = Completer<int>();
      var unlocked = false;

      final result = loadAfterBrowserAudioUnlock(
        unlock: () => unlocked = true,
        load: () {
          expect(unlocked, isTrue);
          return loadResult.future;
        },
      );

      expect(unlocked, isTrue);
      loadResult.complete(7);
      expect(await result, 7);
    },
  );
}
