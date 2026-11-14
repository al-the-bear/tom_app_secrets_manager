// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// An entry's TOTP code with its countdown (part-app, Screens › Entry
/// editor).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// The current code of [totp] and the seconds left in its period, updated
/// every second; the code is copied through the protected clipboard.
class TomSecretsTotpView extends StatefulWidget {
  /// The view of [totp].
  const TomSecretsTotpView({
    super.key,
    required this.totp,
    required this.clipboard,
    this.clock = DateTime.now,
  });

  /// The TOTP.
  final TomSecretsTotp totp;

  /// The clipboard that clears itself.
  final TomProtectedClipboard clipboard;

  /// The time (a test passes its own).
  final DateTime Function() clock;

  @override
  State<TomSecretsTotpView> createState() => _TomSecretsTotpViewState();
}

class _TomSecretsTotpViewState extends State<TomSecretsTotpView> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.clock();
    final period = widget.totp.period;
    final left = period - (now.millisecondsSinceEpoch ~/ 1000) % period;
    final code = widget.totp.code(now);
    final shown = code.length == 6
        ? '${code.substring(0, 3)} ${code.substring(3)}'
        : code;
    return Row(
      children: [
        Text(
          shown,
          key: const Key('tsm-totp-code'),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 20),
        ),
        const SizedBox(width: 12),
        SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(
            key: const Key('tsm-totp-countdown'),
            value: left / period,
            strokeWidth: 3,
          ),
        ),
        const SizedBox(width: 6),
        Text('${left}s'),
        IconButton(
          key: const Key('tsm-totp-copy'),
          tooltip: 'Copy the code',
          icon: const Icon(Icons.copy),
          onPressed: () => unawaited(widget.clipboard.copy(code)),
        ),
      ],
    );
  }
}
