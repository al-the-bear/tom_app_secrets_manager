// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The key reminders in the app (part-key-rotation, Reminders): the keys the
/// service reports due (`status.expiring`, `key_expiry`), a snooze per key
/// that lasts until its next reminder step, and the once-a-day notification.
/// The service decides what is due; the app only shows it.
library;

import 'dart:convert';

import '../ports/desktop_ports.dart';
import 'clients.dart' show tomSecretsReminderStep;
import 'service_connection.dart';

/// The device preference keys of the reminders.
abstract final class TomSecretsReminderKeys {
  /// The snoozed keys: a JSON object of key → the step it was snoozed at.
  static const snoozed = 'reminders.snoozed';

  /// The day (`yyyy-mm-dd`) the last reminder notification was shown.
  static const notifiedOn = 'reminders.notifiedOn';
}

/// A key due a reminder, as the service reported it.
final class TomSecretsDueKey {
  const TomSecretsDueKey._(this.key, this.daysLeft);

  /// From an `expiring` item or a `key_expiry` event.
  static TomSecretsDueKey? of(Map<String, Object?> wire) {
    final key = wire['key'];
    if (key is! String) return null;
    final days = wire['daysLeft'];
    return TomSecretsDueKey._(key, days is int ? days : 0);
  }

  /// Its id (`github-token:<owner>/<repository>`, `vault-keys:<vault>`, …).
  final String key;

  /// Whole days left (negative once expired).
  final int daysLeft;

  /// The key in a few words.
  String get label {
    final subject = key.contains(':')
        ? key.substring(key.indexOf(':') + 1)
        : key;
    final what = switch (key.split(':').first) {
      'github-token' => 'the GitHub token for $subject',
      'vault-keys' => 'the keys of $subject',
      'approver-key' => 'the approver key pair of $subject',
      'link-key' => 'the approval-link key pair of $subject',
      _ => key,
    };
    return daysLeft < 0
        ? '$what (expired)'
        : '$what (${daysLeft == 0 ? 'today' : 'in $daysLeft days'})';
  }

  /// Its reminder step now.
  String get step => tomSecretsReminderStep(daysLeft, DateTime.now());
}

/// The reminders of [connection] with the snoozes kept in [preferences].
final class TomSecretsReminders {
  /// Reminders over [connection] and [preferences].
  const TomSecretsReminders(this.connection, this.preferences);

  /// The connection whose `expiringKeys` say what is due.
  final TomSecretsServiceConnection connection;

  /// Where the snoozes and the last notification day are kept.
  final TomSecretsPreferences preferences;

  Map<String, String> get _snoozed {
    final text = preferences.read(TomSecretsReminderKeys.snoozed);
    if (text == null) return {};
    try {
      return (jsonDecode(text) as Map).cast<String, String>();
    } on FormatException {
      return {};
    }
  }

  /// Every key due now, soonest first.
  List<TomSecretsDueKey> get due =>
      [for (final e in connection.expiringKeys.values) ?TomSecretsDueKey.of(e)]
        ..sort((a, b) => a.daysLeft.compareTo(b.daysLeft));

  /// The keys due and not snoozed at their current step.
  List<TomSecretsDueKey> get shown {
    final snoozed = _snoozed;
    return [
      for (final k in due)
        if (snoozed[k.key] != k.step) k,
    ];
  }

  /// Snoozes [keys] until their next step.
  Future<void> snooze(Iterable<TomSecretsDueKey> keys) async {
    final snoozed = _snoozed;
    final dueNow = {for (final k in due) k.key};
    snoozed.removeWhere((key, _) => !dueNow.contains(key));
    for (final k in keys) {
      snoozed[k.key] = k.step;
    }
    await preferences.write(
      TomSecretsReminderKeys.snoozed,
      jsonEncode(snoozed),
    );
  }

  /// Shows the day's notification through [notifier] when a key is due and
  /// none was shown today (part-key-rotation: once a day while a reminder is
  /// due and the app runs); [onClick] runs on its click. Answers whether it
  /// notified.
  Future<bool> notifyDaily(
    TomSecretsNotifier notifier, {
    required DateTime now,
    void Function()? onClick,
  }) async {
    final keys = due;
    if (keys.isEmpty) return false;
    final today = now.toIso8601String().substring(0, 10);
    if (preferences.read(TomSecretsReminderKeys.notifiedOn) == today) {
      return false;
    }
    await preferences.write(TomSecretsReminderKeys.notifiedOn, today);
    await notifier.notify(
      title: keys.length == 1 ? 'A key is due' : '${keys.length} keys are due',
      body:
          '${keys.take(3).map((k) => k.label).join(', ')}'
          '${keys.length > 3 ? ', …' : ''}. Open Keys to renew or rotate.',
      onClick: onClick,
    );
    return true;
  }
}
