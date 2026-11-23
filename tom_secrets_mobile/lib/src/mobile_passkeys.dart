// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** Android's Credential Manager provider, the Dart side
/// (part-os-integration, part-password-manager, DP-120): the passkeys of
/// the personal and shared vaults signing a sign-in, and new passkeys made
/// and kept in a vault. A system vault's passkeys are never offered, and no
/// passkey is served on the client endpoint.
///
/// - **The caller is checked.** A browser Credential Manager trusts to name
///   the page (the request carries its origin and the client data's hash):
///   the origin must be the relying party or below it, over https. An app:
///   the relying party's Digital Asset Links must list it with its signing
///   certificate ([TomSecretsAssetLinks], as for its logins), and the
///   client data names it (`android:apk-key-hash:<…>`).
/// - **The service lists without unlocking** from the passkey identities
///   (relying party, user name, credential id, never a key), which the app
///   hands to the native side after every unlock and change
///   ([tomSecretsPasskeyIdentities]).
/// - **A sign-in or a new passkey** is answered by the running app after
///   BiometricPrompt, or by `passkeyMain` (lib/main.dart), the app's own
///   unlock on an engine of its own, as for the Autofill service.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import 'mobile_autofill.dart';

/// The channel of the passkey unlock activity (`passkeyMain`'s engine).
const String tomSecretsPasskeyUnlockChannelName =
    'tom_secrets_mobile/passkey_unlock';

/// What Credential Manager asks.
enum TomSecretsPasskeyRequestKind {
  /// A sign-in with the passkey picked ([TomSecretsPasskeyRequest.credentialId]).
  get,

  /// A new passkey.
  create,

  /// The passkeys a sign-in may use, listed after an unlock (none were
  /// known before it).
  entries,
}

/// A Credential Manager request, as the native side sends it.
final class TomSecretsPasskeyRequest {
  const TomSecretsPasskeyRequest({
    required this.kind,
    required this.options,
    required this.packageName,
    this.origin,
    this.clientDataHash,
    this.certificates = const [],
    this.credentialId,
  });

  /// The request the native side sent: `kind`, `requestJson` (WebAuthn's
  /// options as JSON), `packageName`, `origin` (a browser's, when
  /// Credential Manager let it name one), `clientDataHash`, `certificates`
  /// (SHA-256 of the caller's signing certificates, upper-case hex with
  /// colons), `credentialId` (the entry picked).
  factory TomSecretsPasskeyRequest.fromMap(Map<Object?, Object?> m) {
    final json = m['requestJson'];
    final hash = m['clientDataHash'];
    final origin = m['origin'];
    return TomSecretsPasskeyRequest(
      kind: TomSecretsPasskeyRequestKind.values.byName(m['kind'] as String),
      options: json is String && json.isNotEmpty
          ? (jsonDecode(json) as Map).cast<String, Object?>()
          : const {},
      packageName: m['packageName'] as String? ?? '',
      origin: origin is String && origin.isNotEmpty ? origin : null,
      clientDataHash: hash is Uint8List && hash.isNotEmpty ? hash : null,
      certificates: [
        for (final c in (m['certificates'] as List? ?? const [])) '$c',
      ],
      credentialId: m['credentialId'] as String?,
    );
  }

  final TomSecretsPasskeyRequestKind kind;

  /// The WebAuthn options (`PublicKeyCredentialRequestOptionsJSON` or
  /// `…CreationOptionsJSON`).
  final Map<String, Object?> options;

  /// The calling app (a browser for a web page).
  final String packageName;

  /// The page's origin, when a browser named it.
  final String? origin;

  /// The client data's hash, when a browser made the client data.
  final Uint8List? clientDataHash;

  /// The calling app's signing certificates.
  final List<String> certificates;

  /// The credential picked (base64url), for [TomSecretsPasskeyRequestKind.get].
  final String? credentialId;

  /// The relying party: `rp.id` of a creation, `rpId` of a sign-in, else
  /// the origin's host.
  String get rpId {
    final party = options['rp'];
    final rp = kind == TomSecretsPasskeyRequestKind.create
        ? (party is Map ? party['id'] : null)
        : options['rpId'];
    if (rp is String && rp.isNotEmpty) return rp.toLowerCase();
    final host = origin == null ? null : Uri.tryParse(origin!)?.host;
    if (host != null && host.isNotEmpty) return host.toLowerCase();
    throw const TomSecretsPasskeyRefusal(
      TomSecretsPasskeyError.notAllowed,
      'the request names no relying party',
    );
  }

  /// The credential ids the site allows (`allowCredentials`) or excludes
  /// (`excludeCredentials`), base64url.
  List<String> credentialIds(String key) => [
    for (final c in (options[key] as List? ?? const []))
      if (c is Map && c['id'] is String) tomSecretsBase64Url(c['id'] as String),
  ];
}

/// Why a request is refused, as Credential Manager names it.
enum TomSecretsPasskeyError {
  /// The caller may not use the site's passkeys, or none is there.
  notAllowed,

  /// A passkey the site excludes is held already.
  invalidState,

  /// No algorithm the site offers is made here.
  notSupported,

  /// Anything else (the vault could not be written).
  unknown,
}

/// A refused request.
final class TomSecretsPasskeyRefusal implements Exception {
  const TomSecretsPasskeyRefusal(this.error, this.message);

  final TomSecretsPasskeyError error;
  final String message;

  /// The native side's form.
  Map<String, Object?> toMap() => {'error': error.name, 'message': message};

  @override
  String toString() => 'TomSecretsPasskeyRefusal(${error.name}): $message';
}

/// A passkey of a vault: its entry and what the service lists.
final class TomSecretsHeldPasskey {
  const TomSecretsHeldPasskey({
    required this.entryId,
    required this.title,
    required this.passkey,
  });

  /// `<store>/~<32 hex>`.
  final String entryId;
  final String title;
  final TomSecretsPasskey passkey;

  /// What the service lists without unlocking: never the key.
  Map<String, Object?> toIdentity() => {
    'entryId': entryId,
    'title': title,
    'rpId': passkey.relyingParty.toLowerCase(),
    'credentialId': tomSecretsBase64Url(passkey.credentialId),
    'userName': ?passkey.userName,
  };
}

/// The passkeys of [stores]' personal and shared vaults.
List<TomSecretsHeldPasskey> tomSecretsHeldPasskeys(
  Iterable<TomSecretsStore> stores,
) => [
  for (final s in stores)
    if (s.metadata.kind != TomSecretsVaultKind.system)
      for (final p in tomSecretsPasskeysIn(s.file))
        TomSecretsHeldPasskey(
          entryId: '${s.name}/~${tomSecretsUuidHex(p.entry.uuid)}',
          title: p.entry.label ?? p.passkey.relyingParty,
          passkey: p.passkey,
        ),
];

/// The identities the service lists from (relying party, user name,
/// credential id).
List<Map<String, Object?>> tomSecretsPasskeyIdentities(
  Iterable<TomSecretsStore> stores,
) => [for (final p in tomSecretsHeldPasskeys(stores)) p.toIdentity()];

/// Answers Credential Manager's requests from the open vaults.
final class TomSecretsPasskeyAnswerer {
  /// An answerer checking apps' Digital Asset Links with [links].
  TomSecretsPasskeyAnswerer({required this.links});

  final TomSecretsAssetLinks links;

  /// The caller's origin for the client data, once it may use
  /// [request]'s relying party.
  Future<String> callerOrigin(TomSecretsPasskeyRequest request) async {
    final rp = request.rpId;
    final origin = request.origin;
    if (origin != null) {
      final uri = Uri.tryParse(origin);
      final host = uri?.host.toLowerCase() ?? '';
      if (uri?.scheme != 'https' || !(host == rp || host.endsWith('.$rp'))) {
        throw TomSecretsPasskeyRefusal(
          TomSecretsPasskeyError.notAllowed,
          '$origin may not use passkeys of $rp',
        );
      }
      return origin;
    }
    if (request.certificates.isEmpty ||
        !await links.verifies(rp, request.packageName, request.certificates)) {
      throw TomSecretsPasskeyRefusal(
        TomSecretsPasskeyError.notAllowed,
        "$rp's Digital Asset Links do not name ${request.packageName}",
      );
    }
    final certificate = [
      for (final h in request.certificates.first.split(':'))
        int.parse(h, radix: 16),
    ];
    return 'android:apk-key-hash:'
        '${base64Url.encode(certificate).replaceAll('=', '')}';
  }

  /// The client data's hash and, when the provider made it, the client
  /// data (a browser's hash is taken as it came).
  Future<({Uint8List hash, Uint8List? json})> clientData(
    TomSecretsPasskeyRequest request,
    String type,
  ) async {
    final origin = await callerOrigin(request);
    final given = request.clientDataHash;
    if (given != null) return (hash: given, json: null);
    final challenge = request.options['challenge'];
    if (challenge is! String) {
      throw const TomSecretsPasskeyRefusal(
        TomSecretsPasskeyError.notAllowed,
        'the request has no challenge',
      );
    }
    final json = tomSecretsPasskeyClientDataJson(
      type: type,
      challenge: tomSecretsBase64Url(challenge),
      origin: origin,
      packageName: request.origin == null ? request.packageName : null,
    );
    return (
      hash: Uint8List.fromList(crypto.sha256.convert(json).bytes),
      json: json,
    );
  }

  /// The passkeys of [stores] a sign-in of [request] may use (the site's,
  /// of those only the allowed ones when it names some).
  List<TomSecretsHeldPasskey> candidates(
    TomSecretsPasskeyRequest request,
    Iterable<TomSecretsStore> stores,
  ) {
    final rp = request.rpId;
    final allowed = request.credentialIds('allowCredentials').toSet();
    return [
      for (final p in tomSecretsHeldPasskeys(stores))
        if (p.passkey.relyingParty.toLowerCase() == rp &&
            (allowed.isEmpty ||
                allowed.contains(tomSecretsBase64Url(p.passkey.credentialId))))
          p,
    ];
  }

  /// The sign-in with the passkey [request] picked: the
  /// `AuthenticationResponseJSON`.
  Future<String> get(
    TomSecretsPasskeyRequest request,
    Iterable<TomSecretsStore> stores,
  ) async {
    // The caller first: one the site does not name learns nothing.
    final data = await clientData(request, 'webauthn.get');
    final wanted = request.credentialId == null
        ? null
        : tomSecretsBase64Url(request.credentialId!);
    final held = candidates(request, stores)
        .where(
          (p) =>
              wanted == null ||
              tomSecretsBase64Url(p.passkey.credentialId) == wanted,
        )
        .firstOrNull;
    if (held == null) {
      throw TomSecretsPasskeyRefusal(
        TomSecretsPasskeyError.notAllowed,
        'no passkey of ${request.rpId} in your personal and shared vaults',
      );
    }
    final TomSecretsPasskeyAssertion assertion;
    try {
      assertion = await tomSecretsPasskeyAssertion(held.passkey, data.hash);
    } on TomSecretsPasskeyException catch (e) {
      throw TomSecretsPasskeyRefusal(
        TomSecretsPasskeyError.unknown,
        'the passkey of ${held.title} cannot be used: ${e.message}',
      );
    }
    return tomSecretsPasskeyAssertionJson(assertion, clientDataJson: data.json);
  }

  /// A new passkey for [request] (refused when [stores] hold one the site
  /// excludes): the passkey to keep and the `RegistrationResponseJSON`.
  Future<({TomSecretsPasskey passkey, String json})> create(
    TomSecretsPasskeyRequest request,
    Iterable<TomSecretsStore> stores,
  ) async {
    final rp = request.rpId;
    // The caller first: one the site does not name learns nothing.
    final data = await clientData(request, 'webauthn.create');
    final excluded = request.credentialIds('excludeCredentials').toSet();
    if (excluded.isNotEmpty &&
        tomSecretsHeldPasskeys(stores).any(
          (p) =>
              p.passkey.relyingParty.toLowerCase() == rp &&
              excluded.contains(tomSecretsBase64Url(p.passkey.credentialId)),
        )) {
      throw TomSecretsPasskeyRefusal(
        TomSecretsPasskeyError.invalidState,
        'a passkey for this account of $rp is in your vaults already',
      );
    }
    final user = (request.options['user'] as Map?) ?? const {};
    final userId = user['id'];
    if (userId is! String) {
      throw const TomSecretsPasskeyRefusal(
        TomSecretsPasskeyError.notAllowed,
        'the request names no user',
      );
    }
    final algorithms = [
      for (final p
          in (request.options['pubKeyCredParams'] as List? ?? const []))
        if (p is Map && p['alg'] is int) p['alg'] as int,
    ];
    final TomSecretsPasskeyRegistration registration;
    try {
      registration = await tomSecretsCreatePasskey(
        rpId: rp,
        userHandle: tomSecretsDecodeBase64(userId),
        userName: user['name'] as String?,
        algorithms: algorithms.isEmpty ? const [-7] : algorithms,
      );
    } on TomSecretsWebAuthnException catch (e) {
      throw TomSecretsPasskeyRefusal(
        TomSecretsPasskeyError.notSupported,
        e.message,
      );
    }
    return (
      passkey: registration.passkey,
      json: tomSecretsPasskeyRegistrationJson(
        registration,
        clientDataJson: data.json,
      ),
    );
  }

  /// The answer to [request] from [stores] (null while locked: `{locked}`),
  /// a new passkey kept with [keep]: `{json}` (a sign-in or a new passkey)
  /// or `{entries}` (the identities a sign-in may use), with `identities`,
  /// every vault's for the service; a refusal as `{error, message}`.
  Future<Map<String, Object?>> answer(
    TomSecretsPasskeyRequest request,
    Iterable<TomSecretsStore>? stores,
    Future<void> Function(TomSecretsPasskey passkey) keep,
  ) async {
    if (stores == null) return const {'locked': true};
    try {
      switch (request.kind) {
        case TomSecretsPasskeyRequestKind.get:
          return {
            'json': await get(request, stores),
            'identities': tomSecretsPasskeyIdentities(stores),
          };
        case TomSecretsPasskeyRequestKind.entries:
          await callerOrigin(request);
          return {
            'entries': [
              for (final p in candidates(request, stores)) p.toIdentity(),
            ],
            'identities': tomSecretsPasskeyIdentities(stores),
          };
        case TomSecretsPasskeyRequestKind.create:
          final made = await create(request, stores);
          try {
            await keep(made.passkey);
          } on Object catch (e) {
            throw TomSecretsPasskeyRefusal(
              TomSecretsPasskeyError.unknown,
              'the passkey could not be kept in a vault: $e',
            );
          }
          final identities = tomSecretsPasskeyIdentities(stores);
          final id = tomSecretsBase64Url(made.passkey.credentialId);
          return {
            'json': made.json,
            'identities': [
              ...identities,
              if (!identities.any((i) => i['credentialId'] == id))
                {
                  'entryId': '',
                  'title': made.passkey.relyingParty,
                  'rpId': made.passkey.relyingParty.toLowerCase(),
                  'credentialId': id,
                  'userName': ?made.passkey.userName,
                },
            ],
          };
      }
    } on TomSecretsPasskeyRefusal catch (e) {
      return e.toMap();
    }
  }
}

/// The unlock activity's side for a passkey request: what it was started
/// for, and how the Dart side ends it.
abstract interface class TomSecretsPasskeyUnlockPlatform {
  /// The request.
  Future<TomSecretsPasskeyRequest> request();

  /// Ends it with [answer]: `{json}` (a sign-in or a new passkey) or
  /// `{entries}` (the identities a sign-in may use), with the passkey
  /// identities of every vault for the service (`identities`).
  Future<void> done(Map<String, Object?> answer);

  /// Ends it refused.
  Future<void> fail(TomSecretsPasskeyRefusal error);

  /// Ends it without an answer.
  Future<void> cancel();
}

/// [TomSecretsPasskeyUnlockPlatform] over
/// [tomSecretsPasskeyUnlockChannelName].
final class TomSecretsChannelPasskeyUnlock
    implements TomSecretsPasskeyUnlockPlatform {
  const TomSecretsChannelPasskeyUnlock({
    MethodChannel channel = const MethodChannel(
      tomSecretsPasskeyUnlockChannelName,
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<TomSecretsPasskeyRequest> request() async =>
      TomSecretsPasskeyRequest.fromMap(
        await _channel.invokeMapMethod<Object?, Object?>('request') ?? const {},
      );

  @override
  Future<void> done(Map<String, Object?> answer) =>
      _channel.invokeMethod<void>('done', answer);

  @override
  Future<void> fail(TomSecretsPasskeyRefusal error) =>
      _channel.invokeMethod<void>('fail', error.toMap());

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}
