// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// What the Android Autofill service's unlock shows once the vaults are
/// open (part-os-integration, DP-175): it looks the request's logins up,
/// hands them to the service as datasets and ends; with none it says so.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'mobile_autofill.dart';
import 'mobile_engine.dart';

/// The answer to the service's request, after the unlock.
class TomSecretsAutofillAnswer extends StatefulWidget {
  /// The answer from [engine]'s vaults to [platform]'s request, package
  /// matches checked with [links].
  const TomSecretsAutofillAnswer({
    super.key,
    required this.engine,
    required this.platform,
    required this.links,
  });

  final TomSecretsMobileEngine engine;
  final TomSecretsAutofillUnlockPlatform platform;
  final TomSecretsAssetLinks links;

  @override
  State<TomSecretsAutofillAnswer> createState() => _AnswerState();
}

class _AnswerState extends State<TomSecretsAutofillAnswer> {
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_answer());
  }

  Future<void> _answer() async {
    final request = await widget.platform.request();
    final stores = widget.engine.autofillStores;
    final logins = stores == null
        ? const <TomSecretsAutofillLogin>[]
        : await widget.links.check(
            tomSecretsAutofillLogins(stores, request),
            request,
          );
    if (logins.isEmpty) {
      if (mounted) {
        setState(
          () => _message =
              'No login for ${request.target} in your personal and shared '
              'vaults.',
        );
      }
      return;
    }
    await widget.platform.done(logins);
  }

  @override
  Widget build(BuildContext context) => _message == null
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : TomSecretsAutofillMessage(
          message: _message!,
          onClose: widget.platform.cancel,
        );
}

/// A message of the service's unlock with Close (it ends without filling).
class TomSecretsAutofillMessage extends StatelessWidget {
  /// [message], [onClose] ends it.
  const TomSecretsAutofillMessage({
    super.key,
    required this.message,
    required this.onClose,
  });

  final String message;
  final Future<void> Function() onClose;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline_rounded, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              key: const Key('tsm-autofill-message'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('tsm-autofill-close'),
              onPressed: () => unawaited(onClose()),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    ),
  );
}
