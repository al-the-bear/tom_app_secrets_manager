// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The password generator of the entry editor (part-app, Screens › Entry
/// editor): length, character classes, ambiguous characters, the strength,
/// a preview and "Use".
library;

import 'package:flutter/material.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// Shows the generator; answers the password chosen, or null.
Future<String?> tomSecretsShowGenerator(
  BuildContext context, {
  TomSecretsPasswordGenerator? generator,
}) => showDialog<String>(
  context: context,
  builder: (_) => TomSecretsGeneratorDialog(generator: generator),
);

/// The generator dialog.
class TomSecretsGeneratorDialog extends StatefulWidget {
  /// The dialog over [generator] (default a secure one).
  const TomSecretsGeneratorDialog({super.key, this.generator});

  /// The generator.
  final TomSecretsPasswordGenerator? generator;

  @override
  State<TomSecretsGeneratorDialog> createState() =>
      _TomSecretsGeneratorDialogState();
}

class _TomSecretsGeneratorDialogState extends State<TomSecretsGeneratorDialog> {
  late final TomSecretsPasswordGenerator _generator =
      widget.generator ?? TomSecretsPasswordGenerator();
  TomSecretsPasswordPolicy _policy = TomSecretsPasswordPolicy();
  late String _password = _generator.generate(_policy);

  void _apply(TomSecretsPasswordPolicy Function() change) {
    try {
      final policy = change();
      setState(() {
        _policy = policy;
        _password = _generator.generate(policy);
      });
    } on ArgumentError {
      // The last class cannot be switched off, nor the length shortened
      // below the classes: the control stays as it is.
    }
  }

  String get _strength {
    final bits = _policy.entropyBits;
    final label = bits >= 128
        ? 'very strong'
        : bits >= 80
        ? 'strong'
        : bits >= 60
        ? 'fair'
        : 'weak';
    return '${bits.round()} bits, $label';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Generate a password'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _password,
                  key: const Key('tsm-generated'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
                ),
              ),
              IconButton(
                key: const Key('tsm-regenerate'),
                tooltip: 'Generate again',
                icon: const Icon(Icons.refresh),
                onPressed: () => _apply(() => _policy),
              ),
            ],
          ),
          Text(_strength, key: const Key('tsm-strength')),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Length ${_policy.length}'),
              Expanded(
                child: Slider(
                  key: const Key('tsm-length'),
                  value: _policy.length.toDouble(),
                  min: 8,
                  max: 64,
                  divisions: 56,
                  onChanged: (v) =>
                      _apply(() => _policy.copyWith(length: v.round())),
                ),
              ),
            ],
          ),
          for (final cls in TomSecretsCharacterClass.values)
            CheckboxListTile(
              key: Key('tsm-class-${cls.name}'),
              dense: true,
              title: Text(switch (cls) {
                TomSecretsCharacterClass.lower => 'Lower case (a–z)',
                TomSecretsCharacterClass.upper => 'Upper case (A–Z)',
                TomSecretsCharacterClass.digits => 'Digits (0–9)',
                TomSecretsCharacterClass.symbols => 'Symbols',
              }),
              value: _policy.classes.contains(cls),
              onChanged: (on) => _apply(
                () => _policy.copyWith(
                  classes: on == true
                      ? {..._policy.classes, cls}
                      : (_policy.classes.toSet()..remove(cls)),
                ),
              ),
            ),
          CheckboxListTile(
            key: const Key('tsm-ambiguous'),
            dense: true,
            title: const Text('Leave out look-alikes (I l 1 O 0 | ` \' ")'),
            value: _policy.excludeAmbiguous,
            onChanged: (on) =>
                _apply(() => _policy.copyWith(excludeAmbiguous: on == true)),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('tsm-use-generated'),
        onPressed: () => Navigator.of(context).pop(_password),
        child: const Text('Use'),
      ),
    ],
  );
}
