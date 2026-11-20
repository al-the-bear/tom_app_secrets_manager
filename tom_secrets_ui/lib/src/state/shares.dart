// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** Single-entry exports in the app (part-sharing, BP-34): a package
/// found in the user's inbox folder beside a shared vault.
library;

import 'dart:typed_data';

import 'package:tom_secrets_core/tom_secrets_core.dart';

/// A package in the user's inbox folder of a shared vault: found at the
/// sync, opened with the member key where it can be, imported or declined
/// by the user.
final class TomSecretsInboxPackage {
  /// The package [name] in the folder of [member] beside [store]: its
  /// [bytes], the [share] they hold when the member key opened them, else
  /// [passphrase] (written under one) or [problem] (why it does not open).
  const TomSecretsInboxPackage({
    required this.store,
    required this.member,
    required this.name,
    required this.bytes,
    this.share,
    this.passphrase = false,
    this.problem,
  });

  /// The shared vault whose folder holds it.
  final String store;

  /// The member id of the folder (the user's member key's fingerprint).
  final String member;

  /// Its file name, `<date>-<random>.age`.
  final String name;

  /// The `age` file.
  final Uint8List bytes;

  /// The share, when the member key opened it.
  final TomSecretsShare? share;

  /// Whether it is written under a passphrase, which the user gives at the
  /// import.
  final bool passphrase;

  /// Why it does not open, or null.
  final String? problem;

  /// The day it was put in (UTC).
  DateTime? get day => tomSecretsInboxDate(name);

  /// Who sent it, as the share says, or null.
  String? get sender => share?.from?.name;

  /// "1 share from Bob" in words: how many entries, from whom.
  String get title {
    final n = share?.entries.length;
    final what = n == null
        ? 'A share'
        : n == 1
        ? '1 entry'
        : '$n entries';
    return sender == null ? what : '$what from $sender';
  }
}
