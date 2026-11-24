// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** Windows passkeys (part-os-integration, DP-120): the app's side of
/// the Windows 11 passkey plugin `tsm-passkey-plugin`, which ships beside
/// the service in the app's MSIX package.
///
/// - **Registering:** Settings › Integrations › Windows passkeys adds the
///   plugin to Windows (`WebAuthNPluginAddAuthenticator`) and removes it;
///   Windows then lists it under Settings › Accounts › Passkeys › Advanced
///   options, where the user turns it on.
/// - **The names Windows lists:** after every unlock and change, the
///   passkeys of the personal and shared vaults (never a system vault's)
///   are handed to Windows by their credential id, relying party, entry
///   title, user handle and user name
///   (`WebAuthNPluginAuthenticatorAddCredentials`); never a key. The lock
///   keeps them: Windows then asks the plugin, which answers locked.
/// - **Signing and making passkeys** is the service's (protocol.md 5.8):
///   the plugin asks it as the browser host does.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import 'session_state.dart';

/// Where the plugin stands in Windows.
enum TomSecretsWindowsPasskeysStatus {
  /// Not added to Windows.
  notRegistered,

  /// Added, but not turned on in Windows' settings.
  disabled,

  /// Added and turned on.
  enabled,
}

/// A passkey as Windows lists it (`WEBAUTHN_PLUGIN_CREDENTIAL_DETAILS`):
/// its names, never its key.
@immutable
final class TomSecretsWindowsPasskeyName {
  /// The passkey [credentialId] of [rpId] for [userHandle] (both
  /// base64url), shown as [rpName] and [userName].
  const TomSecretsWindowsPasskeyName({
    required this.credentialId,
    required this.rpId,
    required this.rpName,
    required this.userHandle,
    required this.userName,
    required this.displayName,
  });

  /// The credential id (base64url).
  final String credentialId;

  /// The relying party.
  final String rpId;

  /// The relying party's name Windows shows: the entry's title.
  final String rpName;

  /// The user handle (base64url).
  final String userHandle;

  /// The account name.
  final String userName;

  /// The account's display name (the user name; the vaults keep no other).
  final String displayName;

  /// The line `tsm-passkey-plugin --sync-credentials` reads: six
  /// tab-separated base64url fields, the texts as UTF-8.
  String toLine() => [
    credentialId,
    _b64(rpId),
    _b64(rpName),
    userHandle,
    _b64(userName),
    _b64(displayName),
  ].join('\t');

  static String _b64(String text) =>
      base64Url.encode(utf8.encode(text)).replaceAll('=', '');

  @override
  bool operator ==(Object other) =>
      other is TomSecretsWindowsPasskeyName && other.toLine() == toLine();

  @override
  int get hashCode => toLine().hashCode;
}

/// The passkeys of [stores] Windows lists: those of the vaults that are not
/// system vaults ([isSystem]) with a user handle (Windows requires one),
/// sorted by relying party and user.
List<TomSecretsWindowsPasskeyName> tomSecretsWindowsPasskeyNames(
  Iterable<TomSecretsStore> stores, {
  required bool Function(String store) isSystem,
}) {
  final out = <TomSecretsWindowsPasskeyName>[
    for (final store in stores)
      if (!isSystem(store.name))
        for (final indexed in store.entries)
          if (!indexed.isOverlay)
            if (TomSecretsPasskey.fromEntry(indexed.entry) case final p?)
              if (p.userHandle != null && p.userHandle!.isNotEmpty)
                TomSecretsWindowsPasskeyName(
                  credentialId: p.credentialId,
                  rpId: p.relyingParty,
                  rpName: indexed.entry.label ?? p.relyingParty,
                  userHandle: p.userHandle!,
                  userName: p.userName ?? '',
                  displayName: p.userName ?? '',
                ),
  ];
  out.sort(
    (a, b) => a.rpId != b.rpId
        ? a.rpId.compareTo(b.rpId)
        : a.userName.compareTo(b.userName),
  );
  return out;
}

/// The host's Windows passkey plugin (the plugin executable beside the
/// service).
abstract interface class TomSecretsWindowsPasskeysPort {
  /// Where the plugin stands; throws when the plugin cannot be asked (the
  /// message for the user).
  Future<TomSecretsWindowsPasskeysStatus> status();

  /// Adds the plugin to Windows; throws with Windows' refusal.
  Future<void> register();

  /// Removes the plugin and the names Windows keeps.
  Future<void> unregister();

  /// Replaces the passkeys Windows lists with [names].
  Future<void> syncCredentials(List<TomSecretsWindowsPasskeyName> names);
}

/// Keeps Windows' list of the plugin's passkeys current while the plugin is
/// registered: written after every unlock and change of [session].
class TomSecretsWindowsPasskeys extends ChangeNotifier {
  /// Windows passkeys over [port] for [session].
  TomSecretsWindowsPasskeys({required this.port, required this.session}) {
    session.addListener(_onSession);
  }

  /// The plugin.
  final TomSecretsWindowsPasskeysPort port;

  /// The vaults whose passkeys Windows lists.
  final TomSecretsSession session;

  TomSecretsWindowsPasskeysStatus? _status;
  List<TomSecretsWindowsPasskeyName>? _synced;
  Future<void> _work = Future.value();
  bool _disposed = false;
  String? _error;
  bool _busy = false;

  /// Where the plugin stands, as last asked (null before the first ask or
  /// when it could not be asked).
  TomSecretsWindowsPasskeysStatus? get status => _status;

  /// How many passkeys Windows lists, as last written.
  int? get listed => _synced?.length;

  /// The last failure, for the user, or null.
  String? get error => _error;

  /// Whether a registration or removal runs.
  bool get busy => _busy;

  /// Asks where the plugin stands (the user may have turned it on in
  /// Windows' settings meanwhile) and writes the list when it should.
  Future<void> refresh() => _enqueue(_sync);

  /// Adds the plugin to Windows and lists the passkeys.
  Future<void> register() => _run(() async {
    await port.register();
    _synced = null;
    await _sync();
  });

  /// Removes the plugin from Windows, with the names it keeps.
  Future<void> unregister() => _run(() async {
    await port.unregister();
    _synced = null;
    _status = TomSecretsWindowsPasskeysStatus.notRegistered;
  });

  Future<void> _run(Future<void> Function() work) {
    _busy = true;
    _error = null;
    _notify();
    return _enqueue(work).whenComplete(() {
      _busy = false;
      _notify();
    });
  }

  void _onSession() {
    if (session.vaults.isEmpty) return; // locked: the list stays
    unawaited(_enqueue(_sync));
  }

  Future<void> _enqueue(Future<void> Function() work) {
    final next = _work.then((_) => work()).catchError((Object e) {
      _error = e is TomSecretsWindowsPasskeysException ? e.message : '$e';
      _notify();
    });
    _work = next;
    return next;
  }

  Future<void> _sync() async {
    _status = await port.status();
    _notify();
    if (_status == TomSecretsWindowsPasskeysStatus.notRegistered) return;
    if (session.vaults.isEmpty) return;
    final names = tomSecretsWindowsPasskeyNames(
      session.resolution.stores,
      isSystem: (s) => session.kindOf(s) == TomSecretsVaultKind.system,
    );
    if (_synced != null && listEquals(_synced, names)) return;
    await port.syncCredentials(names);
    _synced = names;
    _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_onSession);
    super.dispose();
  }
}

/// A refusal of the plugin or of Windows, for the user.
final class TomSecretsWindowsPasskeysException implements Exception {
  /// The refusal [message].
  const TomSecretsWindowsPasskeysException(this.message);

  /// What the user is told.
  final String message;

  @override
  String toString() => message;
}
