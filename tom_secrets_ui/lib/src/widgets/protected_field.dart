// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A protected value in the editor (part-app, Screens › Entry editor):
/// masked, revealed one at a time for a limited time, copied through the
/// protected clipboard, and a masked field offers no cut or copy
/// (`TomEditingSurface`, kind password).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_ui_support/tom_ui_support.dart';

/// How long a revealed value stays readable.
const Duration tomSecretsRevealFor = Duration(seconds: 30);

/// Which protected field of the editor is revealed: at most one at a time.
class TomSecretsRevealController extends ChangeNotifier {
  /// A controller revealing for [duration].
  TomSecretsRevealController({this.duration = tomSecretsRevealFor});

  /// How long a reveal lasts.
  final Duration duration;

  String? _revealed;
  Timer? _timer;

  /// The field revealed now, or null.
  String? get revealed => _revealed;

  /// Reveals [field] (masking any other); [field] again masks it.
  void toggle(String field) {
    _timer?.cancel();
    if (_revealed == field) {
      _revealed = null;
    } else {
      _revealed = field;
      _timer = Timer(duration, hide);
    }
    notifyListeners();
  }

  /// Masks every field.
  void hide() {
    _timer?.cancel();
    if (_revealed == null) return;
    _revealed = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// A protected field: masked unless revealed, with reveal, copy and an
/// optional extra action (the generator).
class TomSecretsProtectedField extends StatelessWidget {
  /// A field [name] editing [controller].
  const TomSecretsProtectedField({
    super.key,
    required this.name,
    required this.label,
    required this.controller,
    required this.reveal,
    required this.clipboard,
    this.readOnly = false,
    this.extra,
    this.onCopied,
  });

  /// The field's name (its reveal and widget keys).
  final String name;

  /// The label.
  final String label;

  /// The text.
  final TextEditingController controller;

  /// Which field is revealed.
  final TomSecretsRevealController reveal;

  /// The clipboard that clears itself.
  final TomProtectedClipboard clipboard;

  /// Whether it cannot be edited.
  final bool readOnly;

  /// An action beside reveal and copy.
  final Widget? extra;

  /// Told after a copy (a notice).
  final void Function()? onCopied;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: reveal,
    builder: (context, _) {
      final shown = reveal.revealed == name;
      return TomEditingSurface(
        kind: TomEditingSurfaceKind.password,
        child: TextField(
          key: Key('tsm-field-$name'),
          controller: controller,
          readOnly: readOnly,
          obscureText: !shown,
          enableInteractiveSelection: shown,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('tsm-reveal-$name'),
                  tooltip: shown ? 'Hide' : 'Reveal for 30 seconds',
                  icon: Icon(shown ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => reveal.toggle(name),
                ),
                IconButton(
                  key: Key('tsm-copy-$name'),
                  tooltip: 'Copy (cleared after 30 seconds)',
                  icon: const Icon(Icons.copy),
                  onPressed: controller.text.isEmpty
                      ? null
                      : () async {
                          await clipboard.copy(controller.text);
                          onCopied?.call();
                        },
                ),
                ?extra,
              ],
            ),
          ),
        ),
      );
    },
  );
}
