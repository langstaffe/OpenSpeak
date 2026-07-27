import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak_flutter/openspeak_api.dart';
import 'package:openspeak_flutter/realtime_connection_controller.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'realtime controller reads events and isolates replaced sockets',
    () async {
      final controller = RealtimeConnectionController();
      final first = _TestWebSocketChannel();
      final second = _TestWebSocketChannel();
      final events = <RealtimeEvent>[];
      final disconnected = <int>[];

      Future<bool> handleEvent(RealtimeEvent event) async {
        events.add(event);
        return true;
      }

      void onError(Object error, StackTrace stackTrace) => fail('$error');
      void onDisconnected(int generation, int? code, String? reason) {
        disconnected.add(generation);
      }

      await controller.connect(
        open: () async => first,
        handleEvent: handleEvent,
        onError: onError,
        onDisconnected: onDisconnected,
      );
      first.addIncoming(
        jsonEncode({'type': 'first', 'payload': <String, dynamic>{}}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.map((event) => event.type), ['first']);
      expect(controller.connected, isTrue);

      await controller.connect(
        open: () async => second,
        handleEvent: handleEvent,
        onError: onError,
        onDisconnected: onDisconnected,
      );
      second.addIncoming(<int>[]);
      second.addIncoming(
        jsonEncode({'type': 'second', 'payload': <String, dynamic>{}}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.map((event) => event.type), ['first', 'second']);
      expect(disconnected, isEmpty);

      final activeGeneration = controller.generation;
      await second.closeFromServer(code: 1001, reason: 'restart');
      await Future<void>.delayed(Duration.zero);
      expect(controller.connected, isFalse);
      expect(disconnected, [activeGeneration]);
      expect(controller.send('late'), isFalse);

      final stale = _TestWebSocketChannel();
      expect(
        await controller.connect(
          open: () async => stale,
          canActivate: () => false,
          handleEvent: handleEvent,
          onError: onError,
          onDisconnected: onDisconnected,
        ),
        isFalse,
      );
      expect(stale.closed, isTrue);
      expect(controller.generation, activeGeneration);
      controller.dispose();
    },
  );
}

class _TestWebSocketChannel implements WebSocketChannel {
  final _incoming = StreamController<Object?>();
  late final _TestWebSocketSink _sink = _TestWebSocketSink(() {
    if (!_incoming.isClosed) unawaited(_incoming.close());
  });

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<Object?> get stream => _incoming.stream;

  bool get closed => _sink.closed;

  void addIncoming(Object value) => _incoming.add(value);

  Future<void> closeFromServer({int? code, String? reason}) async {
    closeCode = code;
    closeReason = reason;
    await _incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestWebSocketSink implements WebSocketSink {
  _TestWebSocketSink(this._close);

  final void Function() _close;
  final _done = Completer<void>();

  bool get closed => _done.isCompleted;

  @override
  Future<void> get done => _done.future;

  @override
  void add(Object? data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream stream) async {
    await for (final _ in stream) {}
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _close();
    if (!_done.isCompleted) _done.complete();
  }
}
