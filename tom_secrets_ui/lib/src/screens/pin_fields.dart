// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The quick-unlock PIN (part-app, Unlocking; protocol.md 6.4): the form
/// that takes a PIN (at least 6 characters, letters allowed), the step the
/// gate shows after an unlock with the master password, and the dialog
/// Settings › Unlock sets and changes it with.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../state/service_connection.dart';
import 'gate_screens.dart'
    show TomSecretsGateCard, tomSecretsDescribeAdminError;

/// The fewest characters of a PIN (the service checks it too).
const int tomSecretsPinMinLength = 6;

/// Why [pin] is not taken as a new PIN ([confirm]: typed again), or null.
String? tomSecretsPinProblem(String pin, {String? confirm}) {
  if (pin.runes.length < tomSecretsPinMinLength) {
    return 'At least $tomSecretsPinMinLength characters (letters allowed).';
  }
  if (confirm != null && confirm != pin) return 'The two PINs differ.';
  return null;
}

/// A PIN field, with a second one to type it again when [confirm].
class TomSecretsPinFields extends StatefulWidget {
  /// Fields keyed `<keyPrefix>` and `<keyPrefix>-confirm`; [onSubmit] gets
  /// a PIN that passed [tomSecretsPinProblem].
  const TomSecretsPinFields({
    super.key,
    required this.keyPrefix,
    required this.onSubmit,
    this.confirm = true,
    this.label = 'PIN',
    this.submitLabel = 'Save the PIN',
    this.busy = false,
  });

  /// The keys' prefix.
  final String keyPrefix;

  /// Called with the PIN.
  final ValueChanged<String> onSubmit;

  /// Whether the PIN is typed twice.
  final bool confirm;

  /// The first field's label.
  final String label;

  /// The button's label.
  final String submitLabel;

  /// Whether a save runs.
  final bool busy;

  @override
  State<TomSecretsPinFields> createState() => _PinFieldsState();
}

class _PinFieldsState extends State<TomSecretsPinFields> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = tomSecretsPinProblem(
      _pin.text,
      confirm: widget.confirm ? _again.text : null,
    );
    setState(() => _problem = problem);
    if (problem != null) return;
    final pin = _pin.text;
    _pin.clear();
    _again.clear();
    widget.onSubmit(pin);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: Key(widget.keyPrefix),
        controller: _pin,
        obscureText: true,
        autofocus: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => widget.confirm ? null : _submit(),
      ),
      if (widget.confirm)
        TextField(
          key: Key('${widget.keyPrefix}-confirm'),
          controller: _again,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'The PIN again'),
          onSubmitted: (_) => _submit(),
        ),
      if (_problem != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _problem!,
            key: Key('${widget.keyPrefix}-problem'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 12),
      FilledButton(
        key: Key('${widget.keyPrefix}-save'),
        onPressed: widget.busy ? null : _submit,
        child: Text(widget.submitLabel),
      ),
    ],
  );
}

/// What a PIN does and does not survive, for the user.
const String tomSecretsPinSurvives =
    'The PIN undoes an idle or screen lock. A restart (of the service; on a '
    'phone, of the app), "Lock completely", 5 wrong PINs and 7 days after '
    'the last unlock with the master password end it: then the master '
    'password is asked once, and the PIN again after it. The PIN is kept '
    'nowhere, not even on this device\'s disk.';

/// The PIN step the gate shows after an unlock with the master password
/// ([TomSecretsServiceConnection.pinStep]): a new PIN, or the PIN once
/// more after a restart.
class TomSecretsPinStepScreen extends StatefulWidget {
  /// The step.
  const TomSecretsPinStepScreen({super.key});

  @override
  State<TomSecretsPinStepScreen> createState() => _PinStepState();
}

class _PinStepState extends State<TomSecretsPinStepScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _save(String pin) async {
    final c = context.read<TomSecretsServiceConnection>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.setQuickPin(pin);
      c.askPin(null);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final rearm = c.pinStep == TomSecretsPinStep.rearm;
    return TomSecretsGateCard(
      title: rearm ? 'Your PIN' : 'Choose a PIN',
      children: [
        Text(
          rearm
              ? 'Your PIN, to unlock with it again. No PIN is kept anywhere, '
                    'so after a restart it is typed once after the master '
                    'password.'
              : 'At least 6 characters, letters allowed. $tomSecretsPinSurvives',
          key: const Key('tsm-pin-step-text'),
        ),
        const SizedBox(height: 12),
        TomSecretsPinFields(
          keyPrefix: 'tsm-pin-step',
          confirm: !rearm,
          label: rearm ? 'Your PIN' : 'PIN',
          submitLabel: rearm ? 'Unlock with the PIN again' : 'Save the PIN',
          busy: _busy,
          onSubmit: (pin) => unawaited(_save(pin)),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              key: const Key('tsm-pin-step-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          key: const Key('tsm-pin-step-skip'),
          onPressed: _busy ? null : () => c.askPin(null),
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

/// Asks for a new PIN in a dialog (Settings › Unlock) and sets it; answers
/// whether it was set.
Future<bool> tomSecretsSetPinDialog(BuildContext context) async {
  final c = context.read<TomSecretsServiceConnection>();
  final set = await showDialog<bool>(
    context: context,
    builder: (dialog) => _SetPinDialog(connection: c),
  );
  return set ?? false;
}

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog({required this.connection});

  final TomSecretsServiceConnection connection;

  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _save(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.connection.setQuickPin(pin);
      if (mounted) Navigator.of(context).pop(true);
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() {
          _error = tomSecretsDescribeAdminError(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Set the PIN'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('At least 6 characters, letters allowed.'),
          TomSecretsPinFields(
            keyPrefix: 'tsm-pin-dialog',
            busy: _busy,
            onSubmit: (pin) => unawaited(_save(pin)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                key: const Key('tsm-pin-dialog-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
    ],
  );
}
