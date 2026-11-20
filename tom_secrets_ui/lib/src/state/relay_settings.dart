// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The relay settings (part-relay, the Sharing screen): the relays
/// this device knows in order of preference, each with the services it
/// offers, and the default relay for pairing; and the relay a pairing goes
/// through in the app — GitHub reached through the service's `relay.*`
/// requests (`TomSecretsAdminRelayFolder`). A shared vault's mailbox relay
/// is kept in the vault's metadata (`tsm.mailbox-relay`), so every member
/// reads the same one (the session's `setVaultMailboxRelay`).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import 'service_connection.dart';

/// The relays this device knows (device preferences, part-relay).
class TomSecretsRelaySettings extends ChangeNotifier {
  /// The settings kept in [preferences].
  TomSecretsRelaySettings(this.preferences);

  /// Where they are kept.
  final TomSecretsPreferences preferences;

  /// The preference holding the relays, a JSON list of ids.
  static const listKey = 'relays.list';

  /// The preference holding the default relay for pairing.
  static const pairingKey = 'relays.pairing';

  /// The relays in order of preference (an unreadable id is left out).
  List<TomSecretsRelayId> get relays {
    final text = preferences.read(listKey);
    if (text == null) return const [];
    try {
      final list = jsonDecode(text);
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is String) ?_tryParse(item),
      ];
    } on FormatException {
      return const [];
    }
  }

  static TomSecretsRelayId? _tryParse(String text) {
    try {
      return TomSecretsRelayId.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// The default relay for pairing: one of [relays] that offers pairing,
  /// or null (pairing on the LAN and the VPN only).
  TomSecretsRelayId? get pairingRelay {
    final chosen = preferences.read(pairingKey);
    if (chosen == null) return null;
    return relays
        .where(
          (r) =>
              r.text == chosen &&
              r.services.contains(TomSecretsRelayService.pairing),
        )
        .firstOrNull;
  }

  /// The relays that offer [service], in order.
  List<TomSecretsRelayId> offering(TomSecretsRelayService service) => [
    for (final r in relays)
      if (r.services.contains(service)) r,
  ];

  Future<void> _write(List<TomSecretsRelayId> relays) async {
    await preferences.write(
      listKey,
      jsonEncode([for (final r in relays) r.text]),
    );
    notifyListeners();
  }

  /// Adds the relay [text] names at the end; throws [FormatException] for
  /// no relay id, [StateError] when it is listed already. The first relay
  /// that offers pairing becomes the pairing default.
  Future<TomSecretsRelayId> add(String text) async {
    final id = TomSecretsRelayId.parse(text);
    final list = relays;
    if (list.contains(id)) throw StateError('${id.text} is listed already');
    await _write([...list, id]);
    if (pairingRelay == null &&
        id.services.contains(TomSecretsRelayService.pairing)) {
      await setPairingRelay(id);
    }
    return id;
  }

  /// Removes [id] (the pairing default too when it was).
  Future<void> remove(TomSecretsRelayId id) async {
    if (pairingRelay == id) await setPairingRelay(null);
    await _write([
      for (final r in relays)
        if (r != id) r,
    ]);
  }

  /// Moves [id] one place up (-1) or down (1).
  Future<void> move(TomSecretsRelayId id, int by) async {
    final list = [...relays];
    final at = list.indexOf(id);
    final to = at + by;
    if (at < 0 || to < 0 || to >= list.length) return;
    list
      ..removeAt(at)
      ..insert(to, id);
    await _write(list);
  }

  /// Makes [id] the default relay for pairing (null: none).
  Future<void> setPairingRelay(TomSecretsRelayId? id) async {
    await preferences.write(pairingKey, id?.text);
    notifyListeners();
  }
}

/// The relay [id] for this app, over the service [connection]: GitHub
/// through the `relay.*` requests of the served store [stores] names in
/// that repository (`(store, location)`). A relay kind this version does
/// not carry yet, or a repository this machine serves no vault of, throws
/// [TomSecretsRelayException] naming it.
TomSecretsRelay tomSecretsAppRelay(
  TomSecretsRelayId id,
  TomSecretsServiceConnection connection, {
  required List<(String store, String location)> stores,
  String device = 'tsm',
  Duration pollInterval = const Duration(seconds: 2),
}) {
  switch (id.kind) {
    case TomSecretsRelayKind.github:
      final prefix = 'github:${id.address}/';
      final prefixBranch = 'github:${id.address}@';
      final store = stores
          .where(
            (s) =>
                s.$2.startsWith(prefix) ||
                (s.$2.startsWith(prefixBranch) &&
                    s.$2.substring(prefixBranch.length).contains('/')),
          )
          .firstOrNull;
      if (store == null) {
        throw TomSecretsRelayException(
          id.text,
          'this machine serves no vault in ${id.address}: the relay works '
          'through a repository this machine reaches',
        );
      }
      return TomSecretsGitHubRelay(
        id,
        TomSecretsAdminRelayFolder(connection, store.$1),
        device: device,
        pollInterval: pollInterval,
      );
    case TomSecretsRelayKind.server:
    case TomSecretsRelayKind.wormhole:
      throw TomSecretsRelayException(
        id.text,
        'a ${id.kind == TomSecretsRelayKind.server ? 'relay server' : 'magic-wormhole server'} '
        'is not available as a relay in this version; pair through a GitHub '
        'repository, on the same network or over the VPN',
        unsupported: true,
      );
  }
}

/// A store's relay folder through the service's `relay.*` requests (the
/// app holds no GitHub token; the service's storage reaches the
/// repository).
final class TomSecretsAdminRelayFolder implements TomSecretsRelayFolder {
  /// The relay folder of [store]'s repository over [connection].
  TomSecretsAdminRelayFolder(this.connection, this.store);

  /// The admin connection.
  final TomSecretsServiceConnection connection;

  /// The `github:` store whose repository carries the files.
  final String store;

  Future<Map<String, Object?>> _request(String op, Map<String, Object?> m) =>
      connection.request(op, {'store': store, ...m});

  @override
  Future<String?> revisionOf(String folder) async =>
      (await _request('relay.revision', {'folder': folder}))['revision']
          as String?;

  @override
  Future<Map<String, String>> list(String folder) async {
    final files = (await _request('relay.list', {'folder': folder}))['files'];
    return {
      if (files is Map)
        for (final e in files.entries) '${e.key}': '${e.value}',
    };
  }

  @override
  Future<Uint8List?> read(String path) async {
    final bytes = (await _request('relay.read', {'path': path}))['bytes'];
    return bytes is String ? base64.decode(bytes) : null;
  }

  @override
  Future<void> create(
    String path,
    Uint8List bytes, {
    required String message,
  }) async {
    try {
      await _request('relay.create', {
        'path': path,
        'bytes': base64.encode(bytes),
        'message': message,
      });
    } on TomSecretsAdminException catch (e) {
      if (e.details['reason'] == 'exists') {
        throw TomSecretsRelayFileExists(path);
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteFolder(String folder) =>
      _request('relay.deleteFolder', {'folder': folder});

  @override
  Future<void> deleteFile(String path) =>
      _request('relay.deleteFile', {'path': path});
}
