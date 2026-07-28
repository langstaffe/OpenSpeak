import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

ScrollPhysics? get smoothWheelChildPhysics =>
    defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS
    ? null
    : const NeverScrollableScrollPhysics();

double smoothWheelNextPixels({
  required double current,
  required double target,
  required double elapsedSeconds,
}) {
  final alpha = 1 - math.exp(-elapsedSeconds / 0.045);
  return current + (target - current) * alpha;
}

class SmoothListView extends StatefulWidget {
  const SmoothListView({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  State<SmoothListView> createState() => _SmoothListViewState();
}

class _SmoothListViewState extends State<SmoothListView> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothWheelScroll(
      controller: controller,
      child: ListView(
        controller: controller,
        physics: smoothWheelChildPhysics,
        padding: widget.padding,
        children: widget.children,
      ),
    );
  }
}

class SmoothSingleChildScrollView extends StatefulWidget {
  const SmoothSingleChildScrollView({
    super.key,
    required this.child,
    this.padding,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  State<SmoothSingleChildScrollView> createState() =>
      _SmoothSingleChildScrollViewState();
}

class _SmoothSingleChildScrollViewState
    extends State<SmoothSingleChildScrollView> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothWheelScroll(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        physics: smoothWheelChildPhysics,
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}

class SmoothWheelScroll extends StatefulWidget {
  const SmoothWheelScroll({
    super.key,
    required this.controller,
    required this.child,
    this.reverse = false,
  });

  final ScrollController controller;
  final Widget child;
  final bool reverse;

  @override
  State<SmoothWheelScroll> createState() => _SmoothWheelScrollState();
}

class _SmoothWheelScrollState extends State<SmoothWheelScroll> {
  double? _targetPixels;
  late final Ticker _ticker;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _ticker = Ticker(_tick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (resolved is! PointerScrollEvent) return;
      final controller = widget.controller;
      if (!controller.hasClients) return;
      final position = controller.position;
      final rawDelta = resolved.scrollDelta.dy;
      final delta = widget.reverse ? -rawDelta : rawDelta;
      if (delta == 0) return;
      final base =
          _targetPixels?.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ) ??
          position.pixels;
      final target = (base + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - position.pixels).abs() < 0.5) {
        resolved.respond(allowPlatformDefault: false);
        return;
      }
      _targetPixels = target;
      if (delta.abs() < 18) {
        controller.jumpTo(target);
        _targetPixels = null;
      } else {
        _startTicker();
      }
      resolved.respond(allowPlatformDefault: false);
    });
  }

  void _startTicker() {
    _lastTick = null;
    if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final controller = widget.controller;
    final target = _targetPixels;
    if (!controller.hasClients || target == null) {
      _ticker.stop();
      _lastTick = null;
      return;
    }
    final position = controller.position;
    final current = position.pixels;
    final clampedTarget = target
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final distance = clampedTarget - current;
    if (distance.abs() < 0.5) {
      controller.jumpTo(clampedTarget);
      _targetPixels = null;
      _ticker.stop();
      _lastTick = null;
      return;
    }

    final previous = _lastTick;
    _lastTick = elapsed;
    final seconds = previous == null
        ? 1 / 120
        : (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    final next = smoothWheelNextPixels(
      current: current,
      target: clampedTarget,
      elapsedSeconds: seconds,
    ).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if ((next - current).abs() < 0.25) {
      controller.jumpTo(clampedTarget);
      _targetPixels = null;
      _ticker.stop();
      _lastTick = null;
      return;
    }
    controller.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(onPointerSignal: _handlePointerSignal, child: widget.child);
  }
}
