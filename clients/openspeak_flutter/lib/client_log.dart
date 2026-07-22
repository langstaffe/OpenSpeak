import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ClientLog {
  static const _maxBytes = 5 * 1024 * 1024;
  static File? _file;

  static String? get path => _file?.path;

  static Future<void> initialize({Directory? directory}) async {
    if (kIsWeb) {
      write('app', 'started (web)');
      return;
    }
    try {
      final base = directory ?? await getApplicationSupportDirectory();
      final logDirectory = Directory(
        '${base.path}${Platform.pathSeparator}openspeak${Platform.pathSeparator}logs',
      );
      await logDirectory.create(recursive: true);
      final file = File(
        '${logDirectory.path}${Platform.pathSeparator}client.log',
      );
      if (await file.exists() && await file.length() > _maxBytes) {
        final previous = File('${file.path}.old');
        try {
          if (await previous.exists()) await previous.delete();
          await file.rename(previous.path);
        } catch (_) {}
      }
      _file = file;
      write('app', 'started');
    } catch (error) {
      debugPrint('OpenSpeak client log unavailable: $error');
    }
  }

  static void write(String area, String message) {
    final line = '${DateTime.now().toIso8601String()} [$area] $message';
    try {
      _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
    if (kIsWeb || kDebugMode) debugPrint(line);
  }

  static void error(String area, Object error, StackTrace stackTrace) {
    write(area, 'error=$error\n$stackTrace');
  }
}
