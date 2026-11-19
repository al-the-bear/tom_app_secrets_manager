// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Entries the app is asked to show from outside (part-browser: the browser
/// host's `openApp` starts the app with `--show-entry <store>/~<uuid hex>`,
/// or passes it to the running one): kept until the vaults are open and the
/// entry is there, then shown in the vault browser.
library;


import 'package:flutter/foundation.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart' show KdbxUuid;

import 'session_state.dart';

/// The argument that starts the app at an entry; the browser host's launcher
/// (`tom_secrets_browser`) passes the same.
const String tomSecretsShowEntryArgument = '--show-entry';

/// The entry a uuid reference names (`<store>/~<32 hex>`, protocol.md
/// section 4), or null for any other text.
TomSecretsEntryRef? tomSecretsEntryRefOf(String reference) {
  final match = RegExp(r'^(.+)/~([0-9a-fA-F]{32})$').firstMatch(reference);
  if (match == null) return null;
  final hex = match[2]!;
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return TomSecretsEntryRef(match[1]!, KdbxUuid.fromBytes(bytes));
}

/// The entry waiting to be shown.
class TomSecretsEntryRequests extends ChangeNotifier {
  TomSecretsEntryRef? _pending;

  /// The entry waiting, or null.
  TomSecretsEntryRef? get pending => _pending;

  /// Asks for [reference] to be shown; a text that is no uuid reference is
  /// ignored.
  void request(String reference) {
    final ref = tomSecretsEntryRefOf(reference);
    if (ref == null) return;
    _pending = ref;
    notifyListeners();
  }

  /// The entry waiting, taken (null when none).
  TomSecretsEntryRef? take() {
    final ref = _pending;
    _pending = null;
    return ref;
  }
}
