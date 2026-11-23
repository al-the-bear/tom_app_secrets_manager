// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The macOS AutoFill snapshot (part-os-integration, DP-50, DP-51): what the
/// desktop app hands the system's password AutoFill, which runs the
/// product's credential provider extension in a sandbox that cannot reach
/// the service.
///
/// - **What it holds:** the login entries of the personal and shared vaults
///   open in the app (never a system vault's, as for the browser, DP-44):
///   per entry its id, title, user name, password, URLs (`URL` and
///   `KP2A_URL_*`, each with its host, port, path and registrable domain, so
///   the extension matches like the browser without the Public Suffix List),
///   its `tsm.urlMatch` rule, the TOTP when it has one, and its change time.
///   Entries the rule `never` keeps out of the browser are left out.
///   **[C]** Beside them `passkeys`: each passkey of those vaults
///   (`KPEX_PASSKEY_*`) with its entry, relying party, credential id, user
///   handle and name and its private key, which the provider signs with;
///   still never served on the client endpoint.
/// - **[C] Passkeys registered in the provider:** the extension cannot
///   write a vault, so it keeps each new passkey in the pending file of the
///   App Group (sealed under the lasting pending key of the shared keychain
///   group) and uses it from there; the app saves it into a vault at its
///   next sync ([TomSecretsSession.keepPasskey]) and clears it.
/// - **Format** ([TomSecretsAutofillSnapshot]): the magic `TSM-AUTOFILL`, a
///   big-endian 32-bit header length, the header (JSON: `formatVersion`,
///   `keyId`, `written`), a 12-byte nonce, then the JSON document sealed with
///   AES-256-GCM (16-byte tag at the end) under the 256-bit snapshot key; the
///   magic, length and header are the additional data, so the header cannot
///   be changed unseen. Nothing is stored unencrypted, not even a title
///   index (DP-50). CryptoKit opens it (the extension needs no other
///   library).
/// - **The key:** random, made for each unlock, kept in the app's memory
///   while it is unlocked and written by the host into the keychain item
///   the extension reads after Touch ID (or the login password).
/// - **When:** after every unlock, edit and sync, while the provider is
///   turned on in System Settings and in the app; turning it off in the app
///   deletes the snapshot, the key and the QuickType identities, and so
///   does this device's removal (its record in the primary revoked).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:tom_secrets_client/admin.dart' show tomSecretsRandomBytes;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import 'session_state.dart';

/// What the host's AutoFill can do now.
@immutable
final class TomSecretsAutofillState {
  /// The state: [available] (a build with the provider, its App Group and
  /// keychain group), why not ([unavailableReason]), and whether the user
  /// turned the provider on in System Settings ([providerEnabled]).
  const TomSecretsAutofillState({
    required this.available,
    this.unavailableReason,
    this.providerEnabled = false,
  });

  /// No AutoFill on this host.
  static const none = TomSecretsAutofillState(
    available: false,
    unavailableReason: 'AutoFill is a macOS feature',
  );

  /// Whether this build has the provider.
  final bool available;

  /// Why not, for the user.
  final String? unavailableReason;

  /// Whether System Settings › Passwords › AutoFill has it turned on
  /// (`ASCredentialIdentityStore.getState`).
  final bool providerEnabled;
}

/// A QuickType suggestion (`ASPasswordCredentialIdentity`): a domain and a
/// user name, never a password (DP-51); **[C]** with [credentialId] a
/// passkey's (`ASPasskeyCredentialIdentity`: the relying party as
/// [domain], its user handle).
@immutable
final class TomSecretsAutofillIdentity {
  /// [userName] at [domain] for the entry [recordIdentifier]; a passkey's
  /// with [credentialId] and [userHandle] (base64url).
  const TomSecretsAutofillIdentity({
    required this.domain,
    required this.userName,
    required this.recordIdentifier,
    this.credentialId,
    this.userHandle,
  });

  /// The web domain (a host), a passkey's relying party.
  final String domain;

  /// The user name.
  final String userName;

  /// The entry, `<store>/~<32 hex>`.
  final String recordIdentifier;

  /// A passkey's credential id (base64url), else null.
  final String? credentialId;

  /// A passkey's user handle (base64url), when it has one.
  final String? userHandle;

  /// The channel form.
  Map<String, String> toJson() => {
    'domain': domain,
    'userName': userName,
    'recordIdentifier': recordIdentifier,
    'credentialId': ?credentialId,
    'userHandle': ?userHandle,
  };

  @override
  bool operator ==(Object other) =>
      other is TomSecretsAutofillIdentity &&
      other.domain == domain &&
      other.userName == userName &&
      other.recordIdentifier == recordIdentifier &&
      other.credentialId == credentialId &&
      other.userHandle == userHandle;

  @override
  int get hashCode =>
      Object.hash(domain, userName, recordIdentifier, credentialId, userHandle);
}

/// The host's AutoFill (macOS: the App Group container, the keychain, the
/// credential identity store).
abstract interface class TomSecretsAutofillPort {
  /// What it can do now.
  Future<TomSecretsAutofillState> state();

  /// Keeps [key] as the snapshot key [keyId] in the keychain item the
  /// extension reads (Touch ID or the login password, the current
  /// biometric set), replacing the one before.
  Future<void> storeKey(Uint8List key, String keyId);

  /// Writes the sealed snapshot, atomically (a temporary file, a rename).
  Future<void> writeSnapshot(Uint8List sealed);

  /// Deletes the snapshot and its key.
  Future<void> remove();

  /// Replaces the QuickType identities; empty removes them all.
  Future<void> setIdentities(List<TomSecretsAutofillIdentity> identities);

  /// Opens System Settings at the AutoFill providers.
  Future<void> openSettings();

  /// **[C]** The passkeys the extension registered and the app has not
  /// saved yet, each `{id, passkey}` (the passkey as the snapshot names it),
  /// opened with the pending key; none without them.
  Future<List<({String id, TomSecretsPasskey passkey})>> pendingPasskeys();

  /// **[C]** Forgets the pending passkeys [ids] (saved into a vault).
  Future<void> clearPendingPasskeys(List<String> ids);
}

/// The snapshot's binary form.
abstract final class TomSecretsAutofillSnapshot {
  /// The magic the file starts with.
  static final Uint8List magic = Uint8List.fromList(
    ascii.encode('TSM-AUTOFILL'),
  );

  /// The format version of the header and the document.
  static const int formatVersion = 1;

  static final AesGcm _cipher = AesGcm.with256bits();

  /// [document] sealed under [key] ([keyId]) at [written]; [nonce] for a
  /// test vector only (else random).
  static Future<Uint8List> seal(
    Map<String, Object?> document, {
    required Uint8List key,
    required String keyId,
    required DateTime written,
    List<int>? nonce,
  }) async {
    final header = utf8.encode(
      jsonEncode({
        'formatVersion': formatVersion,
        'keyId': keyId,
        'written': written.toUtc().toIso8601String(),
      }),
    );
    final aad = BytesBuilder(copy: false)
      ..add(magic)
      ..add(_uint32(header.length))
      ..add(header);
    final prefix = aad.toBytes();
    final plain = utf8.encode(jsonEncode(document));
    final box = await _cipher.encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: nonce ?? _cipher.newNonce(),
      aad: prefix,
    );
    plain.fillRange(0, plain.length, 0);
    return (BytesBuilder(copy: false)
          ..add(prefix)
          ..add(box.nonce)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .toBytes();
  }

  /// The header and the document of [sealed] opened with [key]; throws
  /// [FormatException] for a file that is not a snapshot and
  /// [SecretBoxAuthenticationError] for a wrong key or a changed file.
  static Future<({Map<String, Object?> header, Map<String, Object?> document})>
  open(Uint8List sealed, Uint8List key) async {
    final m = magic.length;
    if (sealed.length < m + 4 + 12 + 16 ||
        !listEquals(sealed.sublist(0, m), magic)) {
      throw const FormatException('not an AutoFill snapshot');
    }
    final length = ByteData.sublistView(sealed, m, m + 4).getUint32(0);
    final headerEnd = m + 4 + length;
    if (headerEnd + 12 + 16 > sealed.length) {
      throw const FormatException('a cut AutoFill snapshot');
    }
    final header =
        jsonDecode(utf8.decode(sealed.sublist(m + 4, headerEnd)))
            as Map<String, Object?>;
    final box = SecretBox(
      sealed.sublist(headerEnd + 12, sealed.length - 16),
      nonce: sealed.sublist(headerEnd, headerEnd + 12),
      mac: Mac(sealed.sublist(sealed.length - 16)),
    );
    final plain = await _cipher.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: sealed.sublist(0, headerEnd),
    );
    return (
      header: header,
      document: jsonDecode(utf8.decode(plain)) as Map<String, Object?>,
    );
  }

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);
}

/// The snapshot document of the login entries of [stores] that are not
/// system vaults ([isSystem]), written at [written].
Map<String, Object?> tomSecretsAutofillDocument(
  Iterable<TomSecretsStore> stores, {
  required bool Function(String store) isSystem,
  required DateTime written,
}) => {
  'formatVersion': TomSecretsAutofillSnapshot.formatVersion,
  'written': written.toUtc().toIso8601String(),
  'entries': [
    for (final store in stores)
      if (!isSystem(store.name))
        for (final indexed in store.entries) ?tomSecretsAutofillEntry(indexed),
  ],
  'passkeys': [
    for (final store in stores)
      if (!isSystem(store.name))
        for (final indexed in store.entries)
          ?tomSecretsAutofillPasskey(indexed),
  ],
};

/// **[C]** The passkey of an entry for the snapshot, or null (none, an
/// overlay).
Map<String, Object?>? tomSecretsAutofillPasskey(
  TomSecretsIndexedEntry indexed,
) {
  if (indexed.isOverlay) return null;
  final passkey = TomSecretsPasskey.fromEntry(indexed.entry);
  if (passkey == null) return null;
  return {
    'id': '${indexed.store}/~${tomSecretsUuidHex(indexed.entry.uuid)}',
    'store': indexed.store,
    'title': indexed.entry.label ?? '',
    ...tomSecretsAutofillPasskeyJson(passkey),
  };
}

/// **[C]** [passkey] as the snapshot and the pending file name it.
Map<String, Object?> tomSecretsAutofillPasskeyJson(TomSecretsPasskey passkey) =>
    {
      'rpId': passkey.relyingParty,
      'credentialId': passkey.credentialId,
      'userHandle': ?passkey.userHandle,
      'userName': ?passkey.userName,
      'privateKeyPem': passkey.privateKeyPem,
    };

/// **[C]** The passkey of a snapshot or pending-file [json].
TomSecretsPasskey tomSecretsAutofillPasskeyOf(Map<Object?, Object?> json) =>
    TomSecretsPasskey(
      relyingParty: json['rpId']! as String,
      credentialId: json['credentialId']! as String,
      privateKeyPem: json['privateKeyPem']! as String,
      userHandle: json['userHandle'] as String?,
      userName: json['userName'] as String?,
    );

/// One entry of the snapshot, or null when it is not offered (not a login,
/// an overlay, the rule `never`, no web URL).
Map<String, Object?>? tomSecretsAutofillEntry(TomSecretsIndexedEntry indexed) {
  if (indexed.isOverlay) return null;
  final entry = indexed.entry;
  final type = TomSecretsEntryType.of(
    entry.getString(TomSecretsEntryFields.type)?.getText(),
  );
  if (type != TomSecretsEntryType.login) return null;
  final rule = TomSecretsUrlMatchRule.of(
    entry.getString(TomSecretsEntryFields.urlMatch)?.getText(),
  );
  if (rule == TomSecretsUrlMatchRule.never) return null;
  final urls = [
    for (final text in tomSecretsEntryUrls(entry))
      if (TomSecretsSiteUrl.parse(text) case final site?)
        {
          'url': text,
          'scheme': site.scheme,
          'host': site.host,
          'port': ?site.port,
          'path': site.path,
          'site': ?site.registrableDomain,
          if (site.isAddressOrLocalhost) 'address': true,
        },
  ];
  if (urls.isEmpty) return null;
  final totp = TomSecretsTotp.fromEntry(entry);
  final uuid = tomSecretsUuidHex(entry.uuid);
  return {
    'id': '${indexed.store}/~$uuid',
    'store': indexed.store,
    'title': entry.label ?? '',
    'userName': entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
    'password': entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '',
    'rule': rule.name,
    'urls': urls,
    if (totp != null)
      'totp': {
        'secret': base64.encode(totp.secret),
        'digits': totp.digits,
        'period': totp.period,
        'algorithm': totp.algorithm.uriName,
      },
    'modified': ?entry.times.lastModificationTime
        .get()
        ?.toUtc()
        .toIso8601String(),
  };
}

/// The QuickType identities of a snapshot [document]: each entry's user
/// name at each of its web hosts.
List<TomSecretsAutofillIdentity> tomSecretsAutofillIdentities(
  Map<String, Object?> document,
) {
  final out = <TomSecretsAutofillIdentity>{};
  for (final p in (document['passkeys'] as List? ?? const []).cast<Map>()) {
    out.add(
      TomSecretsAutofillIdentity(
        domain: p['rpId'] as String,
        userName: p['userName'] as String? ?? '',
        recordIdentifier: p['id'] as String,
        credentialId: p['credentialId'] as String,
        userHandle: p['userHandle'] as String?,
      ),
    );
  }
  for (final e in (document['entries']! as List).cast<Map>()) {
    final userName = e['userName'] as String;
    if (userName.isEmpty) continue;
    for (final u in (e['urls']! as List).cast<Map>()) {
      out.add(
        TomSecretsAutofillIdentity(
          domain: u['host'] as String,
          userName: userName,
          recordIdentifier: e['id'] as String,
        ),
      );
    }
  }
  return out.toList();
}

/// The preference keys of AutoFill on this device.
abstract final class TomSecretsAutofillKeys {
  /// `off` when the user turned the app's AutoFill off (default on).
  static const enabled = 'autofill.enabled';

  /// `off` when QuickType suggestions are off (default on, DP-51).
  static const quickType = 'autofill.quickType';
}

/// Keeps the snapshot current: written after every unlock, edit and sync
/// of [session] while AutoFill is on (in System Settings and here), with a
/// key made for each unlock; removed when the user turns it off here.
class TomSecretsAutofill extends ChangeNotifier {
  /// AutoFill over [port] for [session], its switches in [preferences].
  TomSecretsAutofill({
    required this.port,
    required this.session,
    required this.preferences,
    DateTime Function()? now,
    Uint8List Function(int length)? randomBytes,
  }) : _now = now ?? DateTime.now,
       _random = randomBytes ?? tomSecretsRandomBytes {
    session.addListener(_onSession);
  }

  /// The host's AutoFill.
  final TomSecretsAutofillPort port;

  /// The vaults it writes.
  final TomSecretsSession session;

  /// Where the switches are kept.
  final TomSecretsPreferences preferences;

  final DateTime Function() _now;
  final Uint8List Function(int length) _random;

  TomSecretsAutofillState _state = const TomSecretsAutofillState(
    available: false,
  );
  Uint8List? _key;
  String? _keyId;
  String? _written;
  List<TomSecretsAutofillIdentity>? _identities;
  Future<void> _work = Future.value();
  String? _device;
  bool _disposed = false;
  String? _error;

  /// What the host can do, as last asked.
  TomSecretsAutofillState get state => _state;

  /// Whether the app's AutoFill is on (default on).
  bool get enabled => preferences.read(TomSecretsAutofillKeys.enabled) != 'off';

  /// Whether QuickType suggestions are on (default on, DP-51).
  bool get quickType =>
      preferences.read(TomSecretsAutofillKeys.quickType) != 'off';

  /// When the snapshot was last written in this run, or null.
  DateTime? get lastWritten => _lastWritten;
  DateTime? _lastWritten;

  /// The last failure, for the user, or null.
  String? get error => _error;

  /// Asks the host what it can do (the user may have turned the provider on
  /// in System Settings meanwhile), and writes when it should.
  Future<void> refresh() => _enqueue(_sync);

  /// Turns the app's AutoFill on or off; off deletes the snapshot, its key
  /// and the identities.
  Future<void> setEnabled(bool on) async {
    await preferences.write(TomSecretsAutofillKeys.enabled, on ? null : 'off');
    _notify();
    await _enqueue(() async {
      if (!on) {
        await _removeAll();
      } else {
        await _sync();
      }
    });
  }

  /// Turns QuickType suggestions on or off.
  Future<void> setQuickType(bool on) async {
    await preferences.write(
      TomSecretsAutofillKeys.quickType,
      on ? null : 'off',
    );
    _notify();
    await _enqueue(() async {
      _identities = null;
      await _sync();
    });
  }

  /// Opens System Settings at the AutoFill providers.
  Future<void> openSettings() => port.openSettings();

  void _onSession() {
    if (session.vaults.isEmpty) {
      // Locked: the snapshot stays (it does not follow the service's lock);
      // the key is forgotten, the next unlock makes a new one.
      _key = null;
      _keyId = null;
      _written = null;
      _device = null;
      return;
    }
    unawaited(_enqueue(_sync));
  }

  Future<void> _enqueue(Future<void> Function() work) {
    final next = _work.then((_) => work()).catchError((Object e) {
      _error = '$e';
      _notify();
    });
    _work = next;
    return next;
  }

  Future<void> _removeAll() async {
    await port.remove();
    await port.setIdentities(const []);
    _key = null;
    _keyId = null;
    _written = null;
    _identities = const [];
  }

  Future<void> _sync() async {
    _state = await port.state();
    _notify();
    if (!enabled || !_state.available || !_state.providerEnabled) return;
    if (session.vaults.isEmpty) return;
    if (await _thisDeviceRemoved()) {
      // A removed device keeps no logins for AutoFill.
      if (_identities == null || _identities!.isNotEmpty || _key != null) {
        await _removeAll();
      }
      return;
    }
    // Passkeys the provider registered: into a vault first, so the snapshot
    // carries them from there.
    final pending = await port.pendingPasskeys();
    if (pending.isNotEmpty) {
      final saved = <String>[];
      for (final p in pending) {
        try {
          await session.keepPasskey(p.passkey);
          saved.add(p.id);
        } on Object catch (e) {
          _error = 'A passkey for ${p.passkey.relyingParty} was not saved: $e';
        }
      }
      if (saved.isNotEmpty) await port.clearPendingPasskeys(saved);
    }
    final now = _now();
    final document = tomSecretsAutofillDocument(
      session.resolution.stores,
      isSystem: (s) => session.kindOf(s) == TomSecretsVaultKind.system,
      written: now,
    );
    final content = jsonEncode([document['entries'], document['passkeys']]);
    if (_key == null) {
      _key = _random(32);
      _keyId = base64Url.encode(_random(9));
      await port.storeKey(_key!, _keyId!);
      _written = null;
    }
    if (content != _written) {
      final sealed = await TomSecretsAutofillSnapshot.seal(
        document,
        key: _key!,
        keyId: _keyId!,
        written: now,
      );
      await port.writeSnapshot(sealed);
      _written = content;
      _lastWritten = now;
      _error = null;
    }
    final identities = quickType
        ? tomSecretsAutofillIdentities(document)
        : const <TomSecretsAutofillIdentity>[];
    if (_identities == null || !listEquals(_identities, identities)) {
      await port.setIdentities(identities);
      _identities = identities;
    }
    _notify();
  }

  /// Whether this device's record in the primary is revoked (`pair.identity`
  /// names the device, `pair.list` the records); a service that cannot tell
  /// counts as not removed.
  Future<bool> _thisDeviceRemoved() async {
    try {
      _device ??=
          (await session.connection.request('pair.identity'))['device']
              as String?;
      final devices =
          (await session.connection.request('pair.list'))['devices'] as List?;
      return (devices ?? const []).cast<Map>().any(
        (d) => d['device'] == _device && d['revoked'] != null,
      );
    } on Object {
      return false;
    }
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

/// **[C]** The pending file of the passkeys the macOS AutoFill provider
/// registered: the snapshot's sealed format ([TomSecretsAutofillSnapshot],
/// header key id `pending`) under the lasting pending key, its document
/// `{formatVersion, entries: [], passkeys: [{id, rpId, credentialId,
/// userHandle?, userName?, privateKeyPem, created}]}`. The extension adds to
/// it; the app opens it, saves the passkeys and writes it back without them.
abstract final class TomSecretsAutofillPending {
  /// The passkeys of [sealed], opened with [key].
  static Future<List<({String id, TomSecretsPasskey passkey})>> open(
    Uint8List sealed,
    Uint8List key,
  ) async {
    final opened = await TomSecretsAutofillSnapshot.open(sealed, key);
    return [
      for (final p
          in (opened.document['passkeys'] as List? ?? const [])
              .cast<Map<Object?, Object?>>())
        (id: p['id']! as String, passkey: tomSecretsAutofillPasskeyOf(p)),
    ];
  }

  /// [passkeys] sealed under [key] at [written]; [nonce] for a test vector
  /// only.
  static Future<Uint8List> seal(
    List<({String id, TomSecretsPasskey passkey})> passkeys, {
    required Uint8List key,
    required DateTime written,
    List<int>? nonce,
  }) => TomSecretsAutofillSnapshot.seal(
    {
      'formatVersion': TomSecretsAutofillSnapshot.formatVersion,
      'entries': const <Object?>[],
      'passkeys': [
        for (final p in passkeys)
          {'id': p.id, ...tomSecretsAutofillPasskeyJson(p.passkey)},
      ],
    },
    key: key,
    keyId: 'pending',
    written: written,
    nonce: nonce,
  );
}
