// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The OS unlock of part-os-unlock on the app's side: the unlock bundle of
/// the primary kept in the host's gated store (Touch ID, Windows Hello), and
/// the service unlocked with it.
///
/// - **What is kept:** the primary's composite key and its repository key
///   (DP-72), read from the service's `vaultKeys` after an unlock, never the
///   password text. One master password opens every vault through the
///   primary, so only the primary's bundle is kept.
/// - **Two lifetimes:** a *session* item in lock mode (c), written at the
///   first unlock with the password and dropped when the service stops, at
///   "Lock completely", or when the service has started again since (its
///   start time is in the item); a *saved* item when the user opts in
///   (BP-37), kept until turned off, the vault is re-keyed or the enrolment
///   changes.
/// - **Fallback, always:** the master password. A bundle the service no
///   longer takes (the vault was re-keyed) and an item the OS no longer
///   releases (a new fingerprint) are forgotten, and the next unlock with
///   the password keeps a new one.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_secrets_client/admin.dart'
    show TomSecretsAdminException, TomSecretsUnlockBundle;
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show tomSecretsCompositeKey;

import '../ports/desktop_ports.dart';
import 'service_connection.dart';

/// The device preference keys of the OS unlock.
abstract final class TomSecretsOsUnlockKeys {
  /// The items kept: JSON `{store: {lifetime, start}}`.
  static const items = 'osUnlock.items';
}

/// One kept item as the device's preferences record it.
@immutable
final class TomSecretsOsUnlockItem {
  /// An item of [store] with [lifetime], written while the service of
  /// [start] ran.
  const TomSecretsOsUnlockItem({
    required this.store,
    required this.lifetime,
    this.start,
  });

  /// The store (the primary).
  final String store;

  /// Session or saved.
  final TomGatedLifetime lifetime;

  /// The service start it was written under.
  final int? start;
}

/// The app's OS unlock.
class TomSecretsOsUnlock extends ChangeNotifier {
  /// The OS unlock of [host] (null: none on this platform) for
  /// [connection], recording its items in [preferences].
  TomSecretsOsUnlock({
    required this.connection,
    required this.host,
    required this.preferences,
  });

  /// The connection.
  final TomSecretsServiceConnection connection;

  /// The host's gated store, or null.
  final TomSecretsOsUnlockHost? host;

  /// The device's preferences.
  final TomSecretsPreferences preferences;

  TomGatedAvailability _availability = TomGatedAvailability.none;
  String? _message;
  bool _busy = false;

  /// The handle of [store]'s item in the gated store.
  static String handleOf(String store) => 'tom_secrets.os_unlock.$store';

  /// The reason the OS prompt shows.
  static const String unlockReason = 'unlock the Tom Secrets Manager';

  /// The reason of a write that prompts (Windows Hello).
  static const String keepReason = 'keep the unlock of the Tom Secrets Manager';

  /// What gates an item here now.
  TomGatedAvailability get availability => _availability;

  /// Whether the OS unlock can be used on this device now.
  bool get offered =>
      host != null && _availability != TomGatedAvailability.none;

  /// Whether it is the gate-only form (macOS without the paid program,
  /// DP-181): the weaker form, named as such.
  bool get gateOnly => _availability == TomGatedAvailability.gateOnly;

  /// The check's name ("Touch ID", "Windows Hello").
  String get label => host?.label ?? 'the OS unlock';

  /// What the last attempt said, for the user, or null.
  String? get message => _message;

  /// Whether an OS unlock or a write runs.
  bool get busy => _busy;

  /// Reads the availability again (the settings, the unlock screen).
  Future<void> refresh() async {
    final store = host?.store;
    var next = TomGatedAvailability.none;
    if (store != null) {
      try {
        next = await store.availability();
      } on Object {
        next = TomGatedAvailability.none;
      }
    }
    if (next != _availability) {
      _availability = next;
      notifyListeners();
    }
  }

  /// The items kept, by store.
  Map<String, TomSecretsOsUnlockItem> get items {
    final text = preferences.read(TomSecretsOsUnlockKeys.items);
    if (text == null) return const {};
    try {
      final json = (jsonDecode(text) as Map).cast<String, Object?>();
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (value is Map)
            key: TomSecretsOsUnlockItem(
              store: key,
              lifetime: value['lifetime'] == 'saved'
                  ? TomGatedLifetime.saved
                  : TomGatedLifetime.session,
              start: value['start'] as int?,
            ),
      };
    } on Object {
      return const {};
    }
  }

  Future<void> _record(Map<String, TomSecretsOsUnlockItem> items) async {
    await preferences.write(
      TomSecretsOsUnlockKeys.items,
      items.isEmpty
          ? null
          : jsonEncode({
              for (final i in items.values)
                i.store: {'lifetime': i.lifetime.name, 'start': ?i.start},
            }),
    );
    notifyListeners();
  }

  /// The primary as the service names it (first in `status`), or the store
  /// of the item kept while locked.
  String? get primary =>
      connection.stores.keys.firstOrNull ?? items.keys.firstOrNull;

  /// The item kept for the primary that may be used now: a saved one, or a
  /// session one of this service start.
  TomSecretsOsUnlockItem? get usable {
    final store = primary;
    final item = store == null ? null : items[store];
    if (item == null) return null;
    if (item.lifetime == TomGatedLifetime.session &&
        item.start != connection.serviceStart) {
      return null;
    }
    return item;
  }

  /// Whether the primary's master password is saved (BP-37).
  bool get saved => items[primary]?.lifetime == TomGatedLifetime.saved;

  /// Whether a session item is kept.
  bool get hasSession =>
      items.values.any((i) => i.lifetime == TomGatedLifetime.session);

  /// After the service was unlocked (with the password, or when lock mode
  /// (c) was chosen): keeps the primary's bundle when it is to be kept
  /// (lock mode (c): a session item; [remember] or saved before: a saved
  /// one) and no usable item is kept yet. A failure leaves the password as
  /// the unlock, with [message] saying why.
  Future<void> keep({bool remember = false}) async {
    await refresh();
    final store = connection.stores.keys.firstOrNull;
    if (!offered || store == null || connection.locked) return;
    await dropStale();
    final current = items[store];
    final lifetime = remember || current?.lifetime == TomGatedLifetime.saved
        ? TomGatedLifetime.saved
        : connection.lockMode == 'c'
        ? TomGatedLifetime.session
        : null;
    if (lifetime == null) return;
    if (current != null &&
        (current.lifetime == lifetime ||
            current.lifetime == TomGatedLifetime.saved)) {
      return;
    }
    await _write(store, lifetime);
  }

  Future<void> _write(String store, TomGatedLifetime lifetime) async {
    final gated = host!.store;
    _busy = true;
    notifyListeners();
    TomSecretsUnlockBundle? bundle;
    Uint8List? plain;
    try {
      final set = await connection.request('vaultKeys', {
        'stores': [store],
      });
      final keys = (((set['stores'] as List).single as Map)['keys'] as Map)
          .cast<String, Object?>();
      final composite = keys['compositeKey'] is String
          ? base64.decode(keys['compositeKey']! as String)
          : tomSecretsCompositeKey(
              password: keys['password'] as String?,
              keyFile: keys['keyFile'] is String
                  ? base64.decode(keys['keyFile']! as String)
                  : null,
            );
      bundle = TomSecretsUnlockBundle(
        compositeKey: composite,
        outerKey: keys['outerKey'] as String?,
      );
      composite.fillRange(0, composite.length, 0);
      plain = bundle.encode();
      final start = connection.serviceStart;
      await gated.write(
        handleOf(store),
        jsonEncode({
          'v': 1,
          'store': store,
          'lifetime': lifetime.name,
          'start': ?start,
          'bundle': base64.encode(plain),
        }),
        lifetime: lifetime,
        reason: keepReason,
      );
      await _record({
        ...items,
        store: TomSecretsOsUnlockItem(
          store: store,
          lifetime: lifetime,
          start: start,
        ),
      });
      _message = null;
    } on TomGatedSecretStoreException catch (e) {
      _message = e.kind == TomGatedSecretErrorKind.cancelled
          ? null
          : '$label could not keep the unlock (${e.kind.name}); the master '
                'password still unlocks.';
    } on TomSecretsAdminException catch (e) {
      _message = 'The unlock could not be kept: ${e.message}';
    } finally {
      bundle?.dispose();
      plain?.fillRange(0, plain.length, 0);
      _busy = false;
      notifyListeners();
    }
  }

  /// Unlocks the service with the primary's kept item: the OS prompt, then
  /// `unlock {vault, bundle}`. Answers whether the service is unlocked; when
  /// not, [message] says why (null when the user cancelled the prompt).
  Future<bool> unlock() async {
    await refresh();
    final item = usable;
    if (!offered || item == null || _busy) return false;
    _busy = true;
    _message = null;
    notifyListeners();
    TomSecretsUnlockBundle? bundle;
    try {
      final String? text;
      try {
        text = await host!.store.read(
          handleOf(item.store),
          reason: unlockReason,
        );
      } on TomGatedSecretStoreException catch (e) {
        switch (e.kind) {
          case TomGatedSecretErrorKind.cancelled:
            return false;
          case TomGatedSecretErrorKind.invalidated:
            await forget(item.store);
            _message =
                '$label changed (a new fingerprint or face): type the master '
                'password once; the next unlock keeps it again.';
          case TomGatedSecretErrorKind.lockedOut:
            _message =
                '$label is locked after too many attempts: type the master '
                'password.';
          case TomGatedSecretErrorKind.unavailable:
            _message =
                '$label cannot be used now (a remote session, a closed lid): '
                'type the master password.';
          case TomGatedSecretErrorKind.failed:
            _message = '$label did not answer: type the master password.';
        }
        return false;
      }
      if (text == null) {
        await forget(item.store);
        return false;
      }
      final json = (jsonDecode(text) as Map).cast<String, Object?>();
      final plain = base64.decode(json['bundle']! as String);
      try {
        bundle = TomSecretsUnlockBundle.decode(plain);
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
      await connection.unlockWithBundle(item.store, bundle);
      return true;
    } on TomSecretsAdminException catch (e) {
      if (e.kind == 'denied' || e.kind == 'not_found') {
        // Re-keyed (perhaps on another machine): the composite key no longer
        // opens the vault.
        await forget(item.store);
        _message =
            'The master password of ${item.store} changed: type the new one; '
            'the next unlock keeps it again.';
      } else {
        _message = 'The unlock failed: ${e.message}';
      }
      return false;
    } on Object {
      await forget(item.store);
      _message = 'The kept unlock cannot be read: type the master password.';
      return false;
    } finally {
      bundle?.dispose();
      _busy = false;
      notifyListeners();
    }
  }

  /// Turns the saved master password of the primary on (writes a saved item
  /// now; the service must be unlocked) or off (forgets it; lock mode (c)
  /// keeps a session item instead).
  Future<void> setSaved(bool on) async {
    final store = connection.stores.keys.firstOrNull;
    if (store == null) return;
    if (on) {
      await _write(store, TomGatedLifetime.saved);
      return;
    }
    await forget(store);
    await keep();
  }

  /// Forgets [store]'s item.
  Future<void> forget(String store) async {
    try {
      await host?.store.delete(handleOf(store));
    } on Object {
      // Gone already, or the store refuses: the record goes anyway.
    }
    await _record({...items}..remove(store));
  }

  /// Forgets every session item: the service stopped, or "Lock completely".
  Future<void> forgetSession() async {
    for (final i in items.values.toList()) {
      if (i.lifetime == TomGatedLifetime.session) await forget(i.store);
    }
  }

  /// Forgets the session items of an older service start (a crash, a
  /// restart): each carries the start it was written under.
  Future<void> dropStale() async {
    final start = connection.serviceStart;
    if (start == null) return;
    for (final i in items.values.toList()) {
      if (i.lifetime == TomGatedLifetime.session && i.start != start) {
        await forget(i.store);
      }
    }
  }

  /// Forgets the session items and locks the service: nothing but the
  /// master password (or a saved item) unlocks it then.
  Future<void> lockCompletely() async {
    await forgetSession();
    await connection.lock();
  }
}
