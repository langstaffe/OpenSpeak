import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'openspeak_api.dart';

RealtimeEvent? decodeRealtimeEvent(Object? raw) {
  if (raw is! String) return null;
  return RealtimeEvent.fromJson(
    (jsonDecode(raw) as Map).cast<String, dynamic>(),
  );
}

class RealtimeConnectionController extends ChangeNotifier {
  WebSocketChannel? _socket;
  int _generation = 0;
  bool _connected = false;

  bool get connected => _connected;
  int get generation => _generation;

  bool isCurrent(int generation) =>
      _socket != null && generation == _generation;

  Future<bool> connect({
    required Future<WebSocketChannel> Function() open,
    required Future<bool> Function(RealtimeEvent event) handleEvent,
    required void Function(Object error, StackTrace stackTrace) onError,
    required void Function(int generation, int? closeCode, String? closeReason)
    onDisconnected,
    bool Function()? canActivate,
  }) async {
    final nextSocket = await open();
    if (canActivate != null && !canActivate()) {
      await nextSocket.sink.close();
      return false;
    }
    final previousSocket = _socket;
    final generation = ++_generation;
    _socket = nextSocket;
    _setConnected(true);
    unawaited(previousSocket?.sink.close());
    unawaited(
      _read(
        nextSocket,
        generation,
        handleEvent: handleEvent,
        onError: onError,
        onDisconnected: onDisconnected,
      ),
    );
    return true;
  }

  bool send(Object data, {int? generation}) {
    if (!_connected ||
        _socket == null ||
        (generation != null && generation != _generation)) {
      return false;
    }
    _socket!.sink.add(data);
    return true;
  }

  Future<void> close() async {
    final closingSocket = _socket;
    _generation += 1;
    _socket = null;
    _setConnected(false);
    await closingSocket?.sink.close();
  }

  Future<void> closeForRetry() async {
    await _socket?.sink.close();
  }

  Future<void> _read(
    WebSocketChannel socket,
    int generation, {
    required Future<bool> Function(RealtimeEvent event) handleEvent,
    required void Function(Object error, StackTrace stackTrace) onError,
    required void Function(int generation, int? closeCode, String? closeReason)
    onDisconnected,
  }) async {
    try {
      await for (final raw in socket.stream) {
        if (!identical(_socket, socket) || generation != _generation) return;
        final event = decodeRealtimeEvent(raw);
        if (event != null && !await handleEvent(event)) return;
      }
    } catch (error, stackTrace) {
      if (identical(_socket, socket) && generation == _generation) {
        onError(error, stackTrace);
      }
    } finally {
      if (identical(_socket, socket) && generation == _generation) {
        _setConnected(false);
        onDisconnected(generation, socket.closeCode, socket.closeReason);
      }
    }
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    notifyListeners();
  }

  @override
  void dispose() {
    final closingSocket = _socket;
    _generation += 1;
    _socket = null;
    _connected = false;
    unawaited(closingSocket?.sink.close());
    super.dispose();
  }
}
