// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A stand-in for the secrets service's admin side, in memory: demo vaults
/// as stored files, `unlock`, `lock`, `status`, `vaultKeys`, `vaultFile`,
/// `save` (with the revision check) and the events. Demo data only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tom_kdbx_store/tom_kdbx_store.dart'
    show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The demo master password.
const demoPassword = 'demo-master-password';

/// A light Argon2id, so a test opens a vault in milliseconds.
const testArgon2 = KdbxArgon2(
  type: KdbxArgon2Type.argon2id,
  memory: 1 << 20,
  iterations: 1,
);

/// One demo store.
final class FakeStore {
  FakeStore(this.name, this.password, this.stored, {this.state = 'current'})
    : revision = tomSecretsBlobId(stored);

  final String name;
  final String password;
  Uint8List stored;
  String revision;
  String state;

  String get location => 'file:/demo/$name.kdbx';
}

/// A vault [name] under [password] with entries added by [fill].
Future<Uint8List> demoVault(
  String name,
  String password,
  void Function(KdbxFile file) fill,
) async {
  final file = tomSecretsNewVault(
    tomSecretsVaultCredentials(password: password),
    name,
    argon2: testArgon2,
  );
  fill(file);
  return file.save();
}

/// Adds an entry at [path] (groups then title) with [fields].
KdbxEntry addEntry(
  KdbxFile file,
  String path, {
  String? password,
  Map<String, String> fields = const {},
}) {
  final parts = path.split('/');
  var group = file.body.rootGroup;
  for (final name in parts.sublist(0, parts.length - 1)) {
    group =
        group.groups.where((g) => g.name.get() == name).firstOrNull ??
        file.createGroup(parent: group, name: name);
  }
  final entry = KdbxEntry.create(file, group)..label = parts.last;
  group.addEntry(entry);
  if (password != null) {
    entry.setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString(password),
    );
  }
  for (final MapEntry(:key, :value) in fields.entries) {
    entry.setString(KdbxKey(key), PlainValue(value));
  }
  return entry;
}

/// The fake service.
final class FakeService implements TomSecretsAdminChannel {
  FakeService(this.stores, {this.locked = true});

  final List<FakeStore> stores;
  bool locked;
  final StreamController<Map<String, Object?>> _events =
      StreamController.broadcast();
  final List<Map<String, Object?>> requests = [];
  final List<Map<String, Object?>> saves = [];
  bool closed = false;

  FakeStore store(String name) => stores.firstWhere((s) => s.name == name);

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  void emit(Map<String, Object?> event) => _events.add(event);

  /// The service dies: the event stream ends.
  Future<void> die() => _events.close();

  /// Another device changed [name]: its file is replaced and announced.
  Future<void> changeElsewhere(
    String name,
    void Function(KdbxFile file) change,
  ) async {
    final s = store(name);
    final file = await KdbxFormat().read(
      s.stored,
      tomSecretsVaultCredentials(password: s.password),
    );
    change(file);
    s.stored = await file.save();
    s.revision = tomSecretsBlobId(s.stored);
    emit({'op': 'store_changed', 'store': name, 'revision': s.revision});
  }

  @override
  Future<Map<String, Object?>> request(
    String op, [
    Map<String, Object?> args = const {},
  ]) async {
    requests.add({'op': op, ...args});
    switch (op) {
      case 'subscribe':
        return {'op': 'ok'};
      case 'status':
        return {
          'op': 'statusReport',
          'locked': locked,
          'lockMode': 'a',
          'protocol': 1,
          'service': {'version': '0.1.0', 'start': 1763100000000},
          'stores': [
            if (!locked)
              for (final s in stores)
                {
                  'name': s.name,
                  'state': s.state,
                  'source': s.state == 'offline' ? 'cache' : 'file',
                  'fetchedAt': '2026-11-14T08:00:00Z',
                  'notPushed': 0,
                },
          ],
          'admins': 1,
          'hardening': {'noCoreDumps': true},
          'expiring': <Object?>[],
        };
      case 'unlock':
        if (args['password'] != demoPassword) {
          throw TomSecretsAdminException(
            'denied',
            'wrong password',
            details: {'reason': 'bad_password'},
          );
        }
        locked = false;
        emit({'op': 'unlocked'});
        return {'op': 'ok'};
      case 'lock':
        locked = true;
        emit({'op': 'locked'});
        return {'op': 'ok'};
      case 'vaultKeys':
        _unlocked();
        final only = (args['stores'] as List?)?.cast<String>();
        return {
          'op': 'vaultKeySet',
          'stores': [
            for (final s in stores)
              if (only == null || only.contains(s.name))
                {
                  'store': s.name,
                  'location': s.location,
                  'keys': {'password': s.password},
                },
          ],
        };
      case 'vaultFile':
        _unlocked();
        final s = store(args['store']! as String);
        return {
          'op': 'vaultFileData',
          'store': s.name,
          'location': s.location,
          'revision': s.revision,
          'bytes': base64.encode(s.stored),
        };
      case 'save':
        _unlocked();
        final s = store(args['store']! as String);
        if (s.state == 'offline') {
          throw TomSecretsAdminException('offline', 'served from the cache');
        }
        if (args['baseRevision'] != s.revision) {
          throw TomSecretsAdminException(
            'denied',
            'stale',
            details: {'reason': 'stale_base'},
          );
        }
        saves.add({'op': op, ...args});
        s.stored = base64.decode(args['bytes']! as String);
        s.revision = tomSecretsBlobId(s.stored);
        emit({'op': 'store_changed', 'store': s.name, 'revision': s.revision});
        return {'op': 'ok'};
      default:
        return {'op': 'ok'};
    }
  }

  void _unlocked() {
    if (locked) throw TomSecretsAdminException('locked', 'locked');
  }

  @override
  Future<void> close() async => closed = true;
}

/// A host whose service is [service], attachable at once; with [setup],
/// a machine that is not set up until that first run wrote its bootstrap.
final class FakeHost implements TomSecretsServiceHost {
  FakeHost(this.service, {this.running = true, this.setup});

  final FakeService service;
  bool running;
  int starts = 0;

  /// The first run of this machine, or null (set up already).
  final TomSecretsFirstRun? setup;

  bool get _setUp => setup == null || File(setup!.bootstrapPath).existsSync();

  @override
  Future<TomSecretsAttach> attach() async => running
      ? TomSecretsAttached(service)
      : _setUp
      ? const TomSecretsNoService()
      : const TomSecretsNotSetUp();

  @override
  Future<TomSecretsAttach> start() async {
    if (!_setUp) return const TomSecretsNotSetUp();
    starts++;
    running = true;
    return TomSecretsAttached(service);
  }

  @override
  Future<TomSecretsFirstRun> firstRun() async =>
      setup ?? (throw StateError('set up already'));

  @override
  Future<TomSecretsAttach> claim(String password, {Uint8List? keyFile}) async =>
      TomSecretsAttached(service);
}

/// The demo stores: `primary` with a login, an API token with a key, a
/// note, an overlay of the login and an entry in a group; `team` with a
/// tagged login.
Future<List<FakeStore>> demoStores() async {
  final primary = await demoVault('primary', demoPassword, (f) {
    addEntry(
      f,
      'Db/Main',
      password: 'demo-db-pw',
      fields: {'UserName': 'demo-user', 'URL': 'https://db.example'},
    );
    addEntry(f, '@host:bomber/Db/Main', password: 'demo-bomber-pw');
    addEntry(
      f,
      'Bot',
      password: 'demo-bot-token',
      fields: {'tsm.key': 'telegram.bot_token', 'tsm.type': 'api-token'},
    );
    addEntry(f, 'Recovery codes', fields: {'tsm.type': 'note'});
  });
  final team = await demoVault('team', 'team-demo-pw', (f) {
    addEntry(f, 'Api/Token', password: 'demo-api-token').tags.set('prod;api');
  });
  return [
    FakeStore('primary', demoPassword, primary),
    FakeStore('team', 'team-demo-pw', team),
  ];
}
