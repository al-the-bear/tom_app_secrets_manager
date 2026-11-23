// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The host's work (part-browser, "What the extension asks for"): each
/// request of the extension turned into client requests on one connection
/// to the service.
///
/// | Request | Host → service | Answer |
/// | --- | --- | --- |
/// | `status` | `hello`, then `match` of a reserved name without waiting | `state`: `running`, `locked` or `not_running` |
/// | `match {url, frameUrl?, wait?}` | `match` (`wait: false` answers `locked` at once; by default it waits for an unlock) | `candidates [{entryId, title, userName, matchedUrl, hasTotp}]`, no value |
/// | `fill {entryId, url, frameUrl?, totp?}` | `match` (the entry must be a candidate of the page), then `getMany` of `UserName`, `Password` and `totp` | `userName`, `password`, `totp?` |
/// | `check {url, frameUrl?, userName?, password}` | `match` without waiting, then `getMany` of the `Password` of the page's logins of that user | `state`: `new`, `changed` (with `entryId`, `userName`), `known` or `unknown`; never a value |
/// | `propose {url, title?, userName, password}` | `propose` | `accepted`, `known` |
/// | `openApp {entryId?}` | — | the desktop app started at the entry |
/// | **[C]** `passkeys {url, rpId, allowCredentials?}` | `passkeys` | `candidates [{entryId, title, userName, credentialId}]`, never a key |
/// | **[C]** `passkeyGet {url, rpId, entryId, clientDataHash}` | `passkeyGet` | `credentialId`, `authenticatorData`, `signature`, `userHandle?` (base64url) |
/// | **[C]** `passkeyCreate {url, rpId, userId, userName, displayName?, algorithms, excludeCredentials?}` | `passkeyCreate` (the app asks the user) | `credentialId`, `authenticatorData`, `attestationObject`, `publicKey`, `publicKeyAlgorithm` |
///
/// Every answer carries the request's `id`; a refusal is `error {kind,
/// message, reason?}` with the service's kind (`not_running` when no
/// service answers).
library;

import 'dart:convert';

import 'package:tom_secrets_client/tom_secrets_client.dart';

import 'app_launcher.dart';

/// What the host asks of the service (the client library, a fake in tests).
abstract interface class TomSecretsBrowserService {
  /// Connects (`hello`); throws `not_running` when no service answers.
  Future<void> open();

  /// `match` of [url] (and [frameUrl]).
  Future<List<TomSecretsLoginCandidate>> match(
    String url, {
    String? frameUrl,
    bool wait = true,
  });

  /// `getMany` of [fields] of the entry [entryId], in order.
  Future<List<String>> values(String entryId, List<String> fields);

  /// `propose`; answers whether the vaults hold it already.
  Future<bool> propose({
    required String url,
    required String userName,
    required String password,
    String? title,
  });

  /// **[C]** `passkeys` of [rpId] for the page [url].
  Future<List<TomSecretsPasskeyCandidate>> passkeys(
    String url,
    String rpId, {
    List<String>? allowCredentials,
  });

  /// **[C]** `passkeyGet`: the service signs with the passkey [entryId].
  Future<TomSecretsPasskeySignature> passkeyGet({
    required String url,
    required String rpId,
    required String entryId,
    required List<int> clientDataHash,
  });

  /// **[C]** `passkeyCreate`: a new passkey once the user confirms it.
  Future<TomSecretsPasskeyCreated> passkeyCreate({
    required String url,
    required String rpId,
    required List<int> userId,
    required String userName,
    String? displayName,
    required List<int> algorithms,
    List<String>? excludeCredentials,
  });

  /// Closes the connection.
  Future<void> close();
}

/// [TomSecretsBrowserService] over the client library.
final class TomSecretsClientBrowserService implements TomSecretsBrowserService {
  /// The service of [client].
  TomSecretsClientBrowserService(this.client);

  /// The client.
  final TomSecretsClient client;

  @override
  Future<void> open() => client.open();

  @override
  Future<List<TomSecretsLoginCandidate>> match(
    String url, {
    String? frameUrl,
    bool wait = true,
  }) => client.match(url, frameUrl: frameUrl, wait: wait);

  @override
  Future<List<String>> values(String entryId, List<String> fields) async {
    final results = await client.getMany([
      for (final f in fields) TomSecretRequest(entryId, field: f),
    ]);
    return [
      for (final r in results)
        if (r.value case final v?) v.text else throw r.error!,
    ];
  }

  @override
  Future<bool> propose({
    required String url,
    required String userName,
    required String password,
    String? title,
  }) => client.propose(
    url: url,
    userName: userName,
    password: password,
    title: title,
  );

  @override
  Future<List<TomSecretsPasskeyCandidate>> passkeys(
    String url,
    String rpId, {
    List<String>? allowCredentials,
  }) => client.passkeys(url, rpId, allowCredentials: allowCredentials);

  @override
  Future<TomSecretsPasskeySignature> passkeyGet({
    required String url,
    required String rpId,
    required String entryId,
    required List<int> clientDataHash,
  }) => client.passkeyGet(
    url: url,
    rpId: rpId,
    entryId: entryId,
    clientDataHash: clientDataHash,
  );

  @override
  Future<TomSecretsPasskeyCreated> passkeyCreate({
    required String url,
    required String rpId,
    required List<int> userId,
    required String userName,
    String? displayName,
    required List<int> algorithms,
    List<String>? excludeCredentials,
  }) => client.passkeyCreate(
    url: url,
    rpId: rpId,
    userId: userId,
    userName: userName,
    displayName: displayName,
    algorithms: algorithms,
    excludeCredentials: excludeCredentials,
  );

  @override
  Future<void> close() => client.close();
}

/// The URL `status` matches to learn whether the service is locked: a
/// reserved name (RFC 2606) no entry holds; the probe is audited as any
/// `match`.
const String tomSecretsBrowserStatusProbe = 'https://tom-secrets.invalid/';

/// The extension's requests, answered.
final class TomSecretsBrowserHost {
  /// The host over [service]; [launcher] starts the desktop app.
  TomSecretsBrowserHost(this.service, {TomSecretsAppLauncher? launcher})
    : launcher = launcher ?? TomSecretsAppLauncher.beside();

  /// The service.
  final TomSecretsBrowserService service;

  /// Starts the desktop app.
  final TomSecretsAppLauncher launcher;

  static Map<String, Object?> _error(
    Object? id,
    String kind,
    String message, [
    String? reason,
  ]) => {
    'id': ?id,
    'error': {'kind': kind, 'message': message, 'reason': ?reason},
  };

  static String? _string(Map<String, Object?> m, String key) {
    final v = m[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// The answer to [request].
  Future<Map<String, Object?>> handle(Map<String, Object?> request) async {
    final id = request['id'];
    final op = request['op'];
    try {
      final answer = switch (op) {
        'status' => await _status(),
        'match' => await _match(request),
        'fill' => await _fill(request),
        'check' => await _check(request),
        'propose' => await _propose(request),
        'openApp' => await _openApp(request),
        'passkeys' => await _passkeys(request),
        'passkeyGet' => await _passkeyGet(request),
        'passkeyCreate' => await _passkeyCreate(request),
        _ => null,
      };
      if (answer == null) {
        return _error(id, 'malformed', 'no request $op', 'op');
      }
      return {'id': ?id, 'op': op, ...answer};
    } on _Malformed catch (e) {
      return _error(id, 'malformed', e.message, e.reason);
    } on TomSecretsClientException catch (e) {
      return _error(
        id,
        e.kind.wireName,
        e.message,
        e.details['reason'] as String?,
      );
    }
  }

  String _need(Map<String, Object?> request, String key) =>
      _string(request, key) ?? (throw _Malformed('$key is needed', key));

  Future<Map<String, Object?>> _status() async {
    try {
      await service.open();
      await service.match(tomSecretsBrowserStatusProbe, wait: false);
      return {'state': 'running'};
    } on TomSecretsClientException catch (e) {
      return switch (e.kind) {
        TomSecretsErrorKind.notRunning => {'state': 'not_running'},
        TomSecretsErrorKind.locked => {'state': 'locked'},
        _ => {
          'state': 'running',
          'refused': {'kind': e.kind.wireName, 'reason': ?e.details['reason']},
        },
      };
    }
  }

  Future<Map<String, Object?>> _match(Map<String, Object?> request) async {
    final candidates = await service.match(
      _need(request, 'url'),
      frameUrl: _string(request, 'frameUrl'),
      wait: request['wait'] != false,
    );
    return {
      'candidates': [
        for (final c in candidates)
          {
            'entryId': c.entryId,
            'title': c.title,
            'userName': c.userName,
            'matchedUrl': c.matchedUrl,
            'hasTotp': c.hasTotp,
          },
      ],
    };
  }

  /// Fills only an entry the page matches: the extension names the entry
  /// and the page, and the host checks the one belongs to the other before
  /// it reads a value.
  Future<Map<String, Object?>> _fill(Map<String, Object?> request) async {
    final entryId = _need(request, 'entryId');
    final candidates = await service.match(
      _need(request, 'url'),
      frameUrl: _string(request, 'frameUrl'),
    );
    final candidate = candidates.where((c) => c.entryId == entryId).firstOrNull;
    if (candidate == null) {
      throw TomSecretsClientException(
        TomSecretsErrorKind.denied,
        'the entry is not a login of this page',
        details: const {'reason': 'not_matched'},
      );
    }
    final totp = request['totp'] == true && candidate.hasTotp;
    final values = await service.values(entryId, [
      'UserName',
      'Password',
      if (totp) 'totp',
    ]);
    return {
      'userName': values[0],
      'password': values[1],
      if (totp) 'totp': values[2],
    };
  }

  /// Whether a login the extension saw submitted is worth proposing
  /// (part-browser, Proposing a login): `new` when the page has no login of
  /// that user, `changed` when its password differs, `known` when a login
  /// of the page holds it, `unknown` when that cannot be told (locked, no
  /// value granted, a change form without a user name and several logins).
  /// The stored passwords are compared here and never answered. Without
  /// [userName] (a password-change form) the page's one login is taken.
  Future<Map<String, Object?>> _check(Map<String, Object?> request) async {
    final password = request['password'];
    if (password is! String || password.isEmpty) {
      throw const _Malformed('password is needed', 'password');
    }
    final userName = _string(request, 'userName');
    final List<TomSecretsLoginCandidate> candidates;
    try {
      candidates = await service.match(
        _need(request, 'url'),
        frameUrl: _string(request, 'frameUrl'),
        wait: false,
      );
    } on TomSecretsClientException catch (e) {
      if (e.kind == TomSecretsErrorKind.locked) return {'state': 'unknown'};
      rethrow;
    }
    final mine = userName == null
        ? (candidates.length == 1
              ? candidates
              : const <TomSecretsLoginCandidate>[])
        : [
            for (final c in candidates)
              if (c.userName == userName) c,
          ];
    if (mine.isEmpty) {
      return {
        'state': userName == null && candidates.isNotEmpty ? 'unknown' : 'new',
      };
    }
    for (final c in mine) {
      final String stored;
      try {
        stored = (await service.values(c.entryId, ['Password'])).single;
      } on TomSecretsClientException {
        return {'state': 'unknown'};
      }
      if (stored == password) return {'state': 'known', 'entryId': c.entryId};
    }
    return {
      'state': 'changed',
      'entryId': mine.first.entryId,
      'userName': mine.first.userName,
    };
  }

  Future<Map<String, Object?>> _propose(Map<String, Object?> request) async {
    final password = request['password'];
    if (password is! String || password.isEmpty) {
      throw const _Malformed('password is needed', 'password');
    }
    final known = await service.propose(
      url: _need(request, 'url'),
      userName: request['userName'] is String
          ? request['userName']! as String
          : '',
      password: password,
      title: _string(request, 'title'),
    );
    return {'accepted': true, 'known': known};
  }

  /// The strings of [request]'s list [key], or null without one.
  static List<String>? _strings(Map<String, Object?> request, String key) {
    final v = request[key];
    if (v == null) return null;
    if (v is! List || v.any((e) => e is! String)) {
      throw _Malformed('$key is a list of strings', key);
    }
    return v.cast<String>();
  }

  static List<int> _bytes(Map<String, Object?> request, String key) {
    final v = request[key];
    try {
      if (v is String && v.isNotEmpty) {
        return base64Url.decode(base64Url.normalize(v));
      }
    } on FormatException {
      // Fall through: malformed.
    }
    throw _Malformed('$key is base64url', key);
  }

  Future<Map<String, Object?>> _passkeys(Map<String, Object?> request) async {
    final found = await service.passkeys(
      _need(request, 'url'),
      _need(request, 'rpId'),
      allowCredentials: _strings(request, 'allowCredentials'),
    );
    return {
      'candidates': [
        for (final c in found)
          {
            'entryId': c.entryId,
            'title': c.title,
            'userName': c.userName,
            'credentialId': c.credentialId,
          },
      ],
    };
  }

  Future<Map<String, Object?>> _passkeyGet(Map<String, Object?> request) async {
    final signed = await service.passkeyGet(
      url: _need(request, 'url'),
      rpId: _need(request, 'rpId'),
      entryId: _need(request, 'entryId'),
      clientDataHash: _bytes(request, 'clientDataHash'),
    );
    return {
      'credentialId': signed.credentialId,
      'authenticatorData': signed.authenticatorData,
      'signature': signed.signature,
      'userHandle': ?signed.userHandle,
    };
  }

  Future<Map<String, Object?>> _passkeyCreate(
    Map<String, Object?> request,
  ) async {
    final algorithms = request['algorithms'];
    if (algorithms is! List || algorithms.any((a) => a is! int)) {
      throw const _Malformed(
        'algorithms is a list of COSE numbers',
        'algorithms',
      );
    }
    final made = await service.passkeyCreate(
      url: _need(request, 'url'),
      rpId: _need(request, 'rpId'),
      userId: _bytes(request, 'userId'),
      userName: request['userName'] is String
          ? request['userName']! as String
          : '',
      displayName: _string(request, 'displayName'),
      algorithms: algorithms.cast<int>(),
      excludeCredentials: _strings(request, 'excludeCredentials'),
    );
    return {
      'credentialId': made.credentialId,
      'authenticatorData': made.authenticatorData,
      'attestationObject': made.attestationObject,
      'publicKey': made.publicKey,
      'publicKeyAlgorithm': made.publicKeyAlgorithm,
    };
  }

  Future<Map<String, Object?>> _openApp(Map<String, Object?> request) async {
    final started = await launcher.open(entry: _string(request, 'entryId'));
    if (!started) {
      throw TomSecretsClientException(
        TomSecretsErrorKind.unavailable,
        'the desktop app is not beside the host',
        details: {'reason': 'no_app'},
      );
    }
    return {'opened': true};
  }
}

final class _Malformed implements Exception {
  const _Malformed(this.message, this.reason);

  final String message;
  final String reason;
}
