// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The app's life while open (part-mobile, Sync): the vaults are looked at
/// on GitHub every minute (the engine fetches those whose refresh interval
/// is due, one conditional request each) and at every return to the
/// foreground; in the background longer than the lock timeout the app
/// locks, dropping every vault from memory (measured on return too, since a
/// suspended app runs no timer).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'mobile_engine.dart';

/// Wraps [child] with the refresh and the background lock of [engine].
class TomSecretsMobileLifecycle extends StatefulWidget {
  /// The lifecycle of [engine]; [tick] and [clock] for tests.
  const TomSecretsMobileLifecycle({
    super.key,
    required this.engine,
    required this.child,
    this.tick = const Duration(minutes: 1),
    this.clock = DateTime.now,
  });

  /// The engine.
  final TomSecretsMobileEngine engine;

  /// The app.
  final Widget child;

  /// How often the due vaults are looked at.
  final Duration tick;

  /// The clock.
  final DateTime Function() clock;

  @override
  State<TomSecretsMobileLifecycle> createState() => _LifecycleState();
}

class _LifecycleState extends State<TomSecretsMobileLifecycle> {
  late final AppLifecycleListener _listener;
  Timer? _ticker;
  Timer? _lockTimer;
  DateTime? _hiddenAt;

  TomSecretsMobileEngine get _engine => widget.engine;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onHide: _hidden, onShow: _shown);
    _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(widget.tick, (_) {
      if (!_engine.isLocked) unawaited(_quiet(_engine.refresh()));
    });
  }

  Future<void> _quiet(Future<Object?> f) async {
    try {
      await f;
    } on Object {
      // The state events carry the reason (offline, token_expired).
    }
  }

  void _hidden() {
    _ticker?.cancel();
    _hiddenAt = widget.clock();
    final seconds = _engine.settings.lockSeconds;
    if (seconds <= 0) {
      _engine.lock();
      return;
    }
    _lockTimer?.cancel();
    _lockTimer = Timer(Duration(seconds: seconds), _engine.lock);
  }

  void _shown() {
    _lockTimer?.cancel();
    final at = _hiddenAt;
    _hiddenAt = null;
    if (at != null &&
        widget.clock().difference(at).inSeconds >=
            _engine.settings.lockSeconds) {
      _engine.lock();
    }
    if (!_engine.isLocked) unawaited(_quiet(_engine.refresh(force: true)));
    _startTicker();
  }

  @override
  void dispose() {
    _listener.dispose();
    _ticker?.cancel();
    _lockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
