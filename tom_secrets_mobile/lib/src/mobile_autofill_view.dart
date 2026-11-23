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
import 'mobile_passkeys.dart';

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

/// **[C]** The answer to the passkey provider's request after the unlock
/// (DP-120): a sign-in signed, a new passkey made and kept in a vault, or
/// the passkeys a sign-in may use; a refusal is shown, Close ends it.
class TomSecretsPasskeyAnswer extends StatefulWidget {
  /// The answer from [engine]'s vaults to [platform]'s request.
  const TomSecretsPasskeyAnswer({
    super.key,
    required this.engine,
    required this.platform,
    required this.answerer,
  });

  final TomSecretsMobileEngine engine;
  final TomSecretsPasskeyUnlockPlatform platform;
  final TomSecretsPasskeyAnswerer answerer;

  @override
  State<TomSecretsPasskeyAnswer> createState() => _PasskeyAnswerState();
}

class _PasskeyAnswerState extends State<TomSecretsPasskeyAnswer> {
  TomSecretsPasskeyRefusal? _refused;

  @override
  void initState() {
    super.initState();
    unawaited(_answer());
  }

  Future<void> _answer() async {
    final request = await widget.platform.request();
    final answer = await widget.answerer.answer(
      request,
      widget.engine.autofillStores,
      widget.engine.keepPasskey,
    );
    final error = answer['error'];
    if (error is String) {
      if (mounted) {
        setState(
          () => _refused = TomSecretsPasskeyRefusal(
            TomSecretsPasskeyError.values.byName(error),
            answer['message'] as String? ?? error,
          ),
        );
      }
      return;
    }
    await widget.platform.done(answer);
  }

  @override
  Widget build(BuildContext context) {
    final refused = _refused;
    return refused == null
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : TomSecretsAutofillMessage(
            message: refused.message,
            onClose: () => widget.platform.fail(refused),
          );
  }
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
