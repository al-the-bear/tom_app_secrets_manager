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
  FakeStore(
    this.name,
    this.password,
    this.stored, {
    this.state = 'current',
    String? location,
    this.keyFile,
    this.outerKey,
  }) : revision = tomSecretsBlobId(stored),
       location = location ?? 'file:/demo/$name.kdbx';

  final String name;

  /// The keys the service holds (a re-keyed save replaces them).
  String password;
  Uint8List? keyFile;
  String? outerKey;
  Uint8List stored;
  String revision;
  String state;

  /// The file on GitHub after a force push ([FakeService.forcePush]), and
  /// the rewritten head; a save meets it.
  Uint8List? remote;
  String? forcedHead;

  /// The rewritten head reported while the service waits for an answer.
  String? rewrittenHead;

  /// The refused edit the service holds meanwhile.
  Uint8List? held;

  /// Its locator (`vault.move` changes it).
  String location;

  /// The keys as `vaultKeySet` carries them.
  Map<String, Object?> get wireKeys => {
    'password': password,
    if (keyFile != null) 'keyFile': base64.encode(keyFile!),
    'outerKey': ?outerKey,
  };
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
  FakeService(this.stores, {this.locked = true, this.unserved = const []});

  final List<FakeStore> stores;

  /// The vaults the primary lists that this machine does not serve
  /// (protocol.md 6.4): editable by name, never in `status`.
  final List<FakeStore> unserved;
  bool locked;
  final StreamController<Map<String, Object?>> _events =
      StreamController.broadcast();
  final List<Map<String, Object?>> requests = [];

  /// The prompts waiting (`approval_needed`), by approval id.
  final Map<String, Map<String, Object?>> waiting = {};

  /// The answers given (`approve`).
  final List<Map<String, Object?>> approvals = [];

  /// The allow list, every host.
  final List<Map<String, Object?>> grants = [
    {
      'id': 'g-1',
      'host': 'demo-host',
      'subject': 'exe /usr/bin/demo-app',
      'secret': 'telegram.bot_token',
      'decision': 'allow',
      'created': '2026-11-01T00:00:00Z',
      'lastUsed': '2026-11-14T09:00:00Z',
      'accepted': true,
    },
    {
      'id': 'g-2',
      'host': 'bomber',
      'subject': 'script /usr/bin/python3 /srv/demo/job.py',
      'secret': 'all',
      'decision': 'never',
      'created': '2026-11-02T00:00:00Z',
      'accepted': true,
    },
  ];

  /// The audit log.
  final List<Map<String, Object?>> audit = [
    {
      'time': '2026-11-15T07:00:00Z',
      'host': 'demo-host',
      'identity': {'kind': 'exe', 'exe': '/usr/bin/demo-app'},
      'refs': ['telegram.bot_token'],
      'outcome': 'allowed',
      'grantId': 'g-1',
    },
    {
      'time': '2026-11-15T06:00:00Z',
      'host': 'bomber',
      'identity': {
        'kind': 'script',
        'exe': '/usr/bin/python3',
        'interpreter': '/usr/bin/python3',
        'script': '/srv/demo/job.py',
      },
      'refs': ['primary/Db/Main'],
      'outcome': 'denied',
    },
  ];

  /// The keys with a date (`keys`), as the service would compute them.
  List<Map<String, Object?>> keys = [];

  /// The answers `history.resolve` got.
  final List<Map<String, Object?>> resolutions = [];

  /// GitHub's branch of [name] is force-pushed to [head] with [file]: the
  /// next save is refused as rewritten.
  void forcePush(String name, Uint8List file, String head) => store(name)
    ..remote = file
    ..forcedHead = head;

  Map<String, Object?> _storeState(FakeStore s) => {
    'op': 'store_state',
    'store': s.name,
    'state': s.state,
    'source': 'github',
    'notPushed': 0,
    if (s.rewrittenHead != null) 'rewritten': {'head': s.rewrittenHead},
  };

  /// How many times `reload` was asked for.
  int reloads = 0;

  /// The hosts paired with this device (an approval token can be made).
  final Set<String> pairedHosts = {'bomber'};

  /// The device settings, as the service keeps them.
  Map<String, Object?> device = const TomSecretsDeviceSettings().toJson();

  /// Whether command-line approvals are on.
  bool cliApprovals = false;

  /// A request waits for an approval: the event goes out.
  void ask(Map<String, Object?> prompt) {
    final event = {'op': 'approval_needed', ...prompt};
    waiting[prompt['approvalId']! as String] = event;
    emit(event);
  }

  /// The prompt [approvalId] ends elsewhere.
  void endPrompt(String approvalId, String outcome) {
    waiting.remove(approvalId);
    emit({
      'op': 'approval_closed',
      'approvalId': approvalId,
      'outcome': outcome,
    });
  }

  final List<Map<String, Object?>> saves = [];
  bool closed = false;

  FakeStore store(String name) =>
      [...stores, ...unserved].firstWhere((s) => s.name == name);

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
                  if (s.rewrittenHead != null)
                    'rewritten': {'head': s.rewrittenHead},
                },
          ],
          'admins': 1,
          'hardening': {'noCoreDumps': true},
          'expiring': [
            for (final k in keys)
              if (k['reminding'] == true)
                {
                  'kind': k['kind'],
                  'key': k['key'],
                  'vault': ?k['vault'],
                  'expiresAt': k['expiresAt'],
                  'daysLeft': k['daysLeft'],
                },
          ],
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
                {'store': s.name, 'location': s.location, 'keys': s.wireKeys},
            for (final s in unserved)
              if (only != null && only.contains(s.name))
                {
                  'store': s.name,
                  'location': s.location,
                  'served': false,
                  'keys': s.wireKeys,
                },
          ],
          'unserved': [
            for (final s in unserved) {'store': s.name, 'location': s.location},
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
          if (unserved.contains(s)) 'served': false,
          'bytes': base64.encode(s.stored),
        };
      case 'save':
        _unlocked();
        final s = store(args['store']! as String);
        if (s.forcedHead != null) {
          // The branch was rewritten without a compaction: refused, held,
          // reported (protocol.md 6.4).
          s.rewrittenHead = s.forcedHead;
          s.held = base64.decode(args['bytes']! as String);
          emit(_storeState(s));
          throw TomSecretsAdminException(
            'denied',
            'the branch was rewritten without a compaction',
            details: {'reason': 'history_rewritten'},
          );
        }
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
        if (failNextSaveOf == s.name) {
          failNextSaveOf = null;
          throw TomSecretsAdminException(
            'offline',
            'the store cannot be reached',
            details: {
              'stores': [s.name],
            },
          );
        }
        final bytes = base64.decode(args['bytes']! as String);
        await _takeKeys(s, bytes, args['keys'] as Map?);
        saves.add({'op': op, ...args});
        s.stored = bytes;
        s.revision = tomSecretsBlobId(s.stored);
        emit({'op': 'store_changed', 'store': s.name, 'revision': s.revision});
        return {'op': 'ok'};
      case 'approve':
        _unlocked();
        final id = args['approvalId'];
        if (waiting.remove(id) == null) {
          throw TomSecretsAdminException('not_found', 'no prompt $id');
        }
        approvals.add(args);
        return {'op': 'ok'};
      case 'grants.list':
        _unlocked();
        final host = args['host'];
        return {
          'op': 'grantList',
          'grants': [
            for (final g in grants)
              if (host == null || g['host'] == host) g,
          ],
        };
      case 'grants.add':
        _unlocked();
        final grant = (args['grant']! as Map).cast<String, Object?>();
        grants.add({
          ...grant,
          'id': 'g-${grants.length + 1}',
          'created': '2026-11-15T08:00:00Z',
          'accepted': true,
        });
        return {'op': 'ok'};
      case 'grants.revoke':
        _unlocked();
        grants.removeWhere(
          (g) => g['host'] == args['host'] && g['id'] == args['grantId'],
        );
        return {'op': 'ok'};
      case 'approval.issue':
        _unlocked();
        if (!pairedHosts.contains(args['host'])) {
          throw TomSecretsAdminException('not_found', 'no paired host');
        }
        return {'op': 'approvalToken', 'token': 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'};
      case 'audit.query':
        _unlocked();
        final ref = args['ref'];
        return {
          'op': 'auditRecords',
          'records': [
            for (final r in audit)
              if (ref == null || (r['refs']! as List).contains(ref)) r,
          ],
        };
      case 'approvers.cliSwitch':
        _unlocked();
        cliApprovals = args['on']! as bool;
        return {'op': 'ok'};
      case 'history.resolve':
        _unlocked();
        final s = store(args['store']! as String);
        if (s.rewrittenHead == null) {
          throw TomSecretsAdminException('not_found', 'nothing waits');
        }
        resolutions.add(args);
        // The fake does not merge: a merge keeps the held edit.
        s.stored = args['take'] == 'remote' ? s.remote! : s.held!;
        s.revision = tomSecretsBlobId(s.stored);
        s
          ..rewrittenHead = null
          ..forcedHead = null
          ..remote = null
          ..held = null;
        emit(_storeState(s));
        emit({'op': 'store_changed', 'store': s.name, 'revision': s.revision});
        return {'op': 'ok', 'revision': s.revision, 'conflicts': 0};
      case 'keys':
        _unlocked();
        return {'op': 'keyList', 'keys': keys};
      case 'vault.move':
        _unlocked();
        final s = store(args['store']! as String);
        moves.add(args);
        final to = args['location']! as String;
        final expected = s.location.endsWith(tomSecretsOuterSuffix)
            ? s.location.substring(
                0,
                s.location.length - tomSecretsOuterSuffix.length,
              )
            : '${s.location}$tomSecretsOuterSuffix';
        if (to != expected) {
          throw TomSecretsAdminException(
            'malformed',
            'location',
            details: {'reason': 'location'},
          );
        }
        if (args['baseRevision'] != s.revision) {
          throw TomSecretsAdminException(
            'denied',
            'stale',
            details: {'reason': 'stale_base'},
          );
        }
        final keys = (args['keys']! as Map).cast<String, Object?>();
        final kf = keys['keyFile'] as String?;
        final bytes = base64.decode(args['bytes']! as String);
        try {
          await tomSecretsDecodeStored(
            to,
            bytes,
            tomSecretsVaultCredentials(
              password: keys['password'] as String?,
              keyFile: kf == null ? null : base64.decode(kf),
            ),
            outerKey: keys['outerKey'] as String?,
          );
        } on Object {
          throw TomSecretsAdminException(
            'malformed',
            'bytes',
            details: {'reason': 'bytes'},
          );
        }
        s
          ..location = to
          ..outerKey = keys['outerKey'] as String?
          ..stored = bytes
          ..revision = tomSecretsBlobId(bytes);
        final primary = stores.first;
        if (s != primary) {
          // The service writes the vault's entry in the primary.
          final file = await tomSecretsDecodeStored(
            primary.location,
            primary.stored,
            tomSecretsVaultCredentials(
              password: primary.password,
              keyFile: primary.keyFile,
            ),
            outerKey: primary.outerKey,
          );
          final list = TomSecretsPrimaryVaults(file);
          final old = list.byName(s.name);
          if (old != null) {
            list.put(
              TomSecretsVaultKeys(
                name: old.name,
                locator: to,
                password: old.password,
                keyFile: old.keyFile,
                outerKey: s.outerKey,
                githubToken: old.githubToken,
                expires: old.expires,
              ),
            );
          }
          primary
            ..stored = await tomSecretsEncodeStored(
              primary.location,
              file,
              outerKey: primary.outerKey,
            )
            ..revision = tomSecretsBlobId(primary.stored);
        }
        emit({'op': 'store_changed', 'store': s.name, 'revision': s.revision});
        return {'op': 'ok', 'location': to, 'revision': s.revision};
      case 'keys.rotate':
        _unlocked();
        pairRotations.add(args);
        return {
          'op': 'keysRotated',
          'approverKeyId': 'fedcba98765432100123456789abcdef',
          'resigned': 2,
          'delivered': ['bigbeast'],
          'pending': ['legiondary01'],
        };
      case 'token.set':
        _unlocked();
        tokenRequests.add(args);
        final reason = refusedTokens[args['token']];
        if (reason != null) {
          throw TomSecretsAdminException(
            'denied',
            'refused',
            details: {'reason': reason},
          );
        }
        return {
          'op': 'tokenSet',
          'repository': args['repository'],
          'where': 'keychain',
          'expiresAt': '2027-02-13T09:00:00.000Z',
        };
      case 'pair.identity':
        _unlocked();
        return {'op': 'pairIdentity', 'device': 'mbp', ...?pairIdentity};
      case 'pair.record':
        _unlocked();
        pairRecords.add(args);
        final record = (args['record'] as Map?)?.cast<String, Object?>();
        pairedDevices
          ..removeWhere((d) => d.device == args['device'])
          ..add(
            TomSecretsDeviceRecord(
              device: args['device']! as String,
              platform: record?['platform'] as String?,
              paired: DateTime.utc(2026, 11, 15),
              pairedBy: 'mbp',
              keyIds: [
                for (final k in (record?['keyIds'] as List? ?? [])) '$k',
              ],
              approverKeyId: args['approver'] == null ? null : 'a1b2c3d4',
              linkKeySince: DateTime.utc(2026, 11, 15),
            ),
          );
        return {'op': 'ok'};
      case 'pair.revoke':
        _unlocked();
        final at = pairedDevices.indexWhere((d) => d.device == args['device']);
        if (at < 0) {
          throw TomSecretsAdminException(
            'not_found',
            'no such device',
            details: {'device': args['device']},
          );
        }
        final d = pairedDevices[at];
        pairedDevices[at] = TomSecretsDeviceRecord(
          device: d.device,
          platform: d.platform,
          paired: d.paired,
          pairedBy: d.pairedBy,
          keyIds: d.keyIds,
          approverKeyId: d.approverKeyId,
          approverKeySince: d.approverKeySince,
          linkKeySince: d.linkKeySince,
          revoked: DateTime.utc(2026, 11, 16),
        );
        return {'op': 'ok'};
      case 'pair.list':
        _unlocked();
        return {
          'op': 'pairedDevices',
          'devices': [for (final d in pairedDevices) d.toJson()],
        };
      case 'compact':
        _unlocked();
        compactions.add(args);
        return {
          'op': 'compacted',
          'repository': args['repository'],
          'compacted': true,
          'oldHead': 'a' * 40,
          'newHead': 'b' * 40,
          'kept': 0,
        };
      case 'reload':
        _unlocked();
        reloads++;
        return {'op': 'ok'};
      case 'settings.get':
        _unlocked();
        return {
          'op': 'deviceSettings',
          'device': device,
          'cliApprovals': cliApprovals,
          'stores': [
            for (final s in stores) s.name,
            for (final s in unserved) s.name,
          ],
        };
      case 'settings.set':
        _unlocked();
        final old = device;
        device = (args['device']! as Map).cast<String, Object?>();
        return {
          'op': 'ok',
          'nextUnlock': [
            if ('${old['servedStores']}' != '${device['servedStores']}')
              'servedStores',
            if (old['defaultEnvironment'] != device['defaultEnvironment'])
              'defaultEnvironment',
          ],
        };
      default:
        return {'op': 'ok'};
    }
  }

  /// The keys a save of [s] is written with (protocol.md 6.4): the keys
  /// held; the primary's [newKeys]; or, for a further vault, the keys the
  /// primary lists for it now (a re-keyed save). Else `malformed`. A saved
  /// primary's vault list is what the further vaults' re-keyed saves take.
  Future<void> _takeKeys(FakeStore s, Uint8List bytes, Map? newKeys) async {
    final primary = s == stores.first;
    if (newKeys != null && !primary) {
      throw TomSecretsAdminException(
        'malformed',
        'keys',
        details: {'reason': 'keys'},
      );
    }
    Future<KdbxFile?> open(String? pw, Uint8List? kf, String? outer) async {
      try {
        return await tomSecretsDecodeStored(
          s.location,
          bytes,
          tomSecretsVaultCredentials(password: pw, keyFile: kf),
          outerKey: outer,
        );
      } on Object {
        return null;
      }
    }

    Never malformed() => throw TomSecretsAdminException(
      'malformed',
      'the file does not open with the store\'s keys',
      details: {'reason': 'bytes'},
    );
    KdbxFile? file;
    if (newKeys != null) {
      final kf = newKeys['keyFile'] as String?;
      final keyFile = kf == null ? null : base64.decode(kf);
      file = await open(
        newKeys['password'] as String?,
        keyFile,
        newKeys['outerKey'] as String?,
      );
      if (file == null) malformed();
      s
        ..password = newKeys['password']! as String
        ..keyFile = keyFile
        ..outerKey = newKeys['outerKey'] as String?;
      rekeyedSaves.add(s.name);
    } else {
      file = await open(s.password, s.keyFile, s.outerKey);
      final entry = listed[s.name];
      if (file == null && entry != null) {
        final kf = entry.keyFile == null
            ? null
            : Uint8List.fromList(entry.keyFile!);
        file = await open(entry.password, kf, entry.outerKey);
        if (file != null) {
          s
            ..password = entry.password ?? ''
            ..keyFile = kf
            ..outerKey = entry.outerKey;
          rekeyedSaves.add(s.name);
        }
      }
      if (file == null) malformed();
    }
    if (primary) {
      listed = {
        for (final v in TomSecretsPrimaryVaults(file).list()) v.name: v,
      };
    }
  }

  /// The vaults the saved primary lists, by name (empty until the primary
  /// is saved).
  Map<String, TomSecretsVaultKeys> listed = {};

  /// The stores whose save was re-keyed, in order.
  final List<String> rekeyedSaves = [];

  /// The next save of this store fails as offline (once).
  String? failNextSaveOf;

  /// The `compact` requests.
  final List<Map<String, Object?>> compactions = [];

  /// The `vault.move` requests.
  final List<Map<String, Object?>> moves = [];

  /// The `keys.rotate` requests.
  final List<Map<String, Object?>> pairRotations = [];

  /// The `token.set` requests.
  final List<Map<String, Object?>> tokenRequests = [];

  /// This device's public keys (`pair.identity`), set by a pairing test.
  Map<String, Object?>? pairIdentity;

  /// The `pair.record` requests.
  final List<Map<String, Object?>> pairRecords = [];

  /// The device records (`pair.list`); `pair.record` and `pair.revoke`
  /// change them.
  final List<TomSecretsDeviceRecord> pairedDevices = [];

  /// Tokens `token.set` refuses, with the `denied` reason.
  final Map<String, String> refusedTokens = {};

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

  /// How often the connection reported the service stopped.
  int stoppedReports = 0;

  @override
  Future<void> serviceStopped() async => stoppedReports++;

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

/// The configuration of the system demo: host, platform, env (default
/// `dev`); the files `primary` (dev), `prod` and `staging` (not served).
const systemConfig = '''
dimensions:
  - name: host
  - name: platform
  - name: env
    default: dev
stores:
  dev:
    - name: primary
      path: /demo/primary.kdbx
  prod:
    - name: prod
      path: /demo/prod.kdbx
  staging:
    - name: staging
      path: /demo/staging.kdbx
''';

/// The demo grants' last use.
final demoLastUsed = DateTime.utc(2026, 11, 14, 9);

/// The system demo: `primary` (kind system, the configuration, grants) with
/// `Api/Stripe` (key `stripe.key`, an overlay for bomber), `Api/Twin` (two
/// overlays for bomber: ambiguous) and `Box` (a conflict on Password and
/// Notes, the older side in its history); `prod` (bound `env:prod`) with
/// `Stripe` (key `stripe.key`). The staging vault (bound `env:staging`) is
/// returned beside them: the primary lists it, this machine does not serve
/// it. Demo data only.
Future<({List<FakeStore> stores, FakeStore staging})> systemStores() async {
  final primary = await demoVault('primary', demoPassword, (f) {
    TomSecretsMetadata(
      store: 'primary',
      kind: TomSecretsVaultKind.system,
      configYaml: systemConfig,
    ).writeTo(f);
    addEntry(
      f,
      'Api/Stripe',
      password: 'demo-stripe-dev',
      fields: {'tsm.key': 'stripe.key', 'tsm.type': 'api-token'},
    );
    addEntry(f, '@host:bomber/Api/Stripe', password: 'demo-stripe-bomber');
    addEntry(f, 'Api/Twin', password: 'demo-twin');
    addEntry(f, '@host:bomber/Api/Twin', password: 'demo-twin-a');
    addEntry(f, '@host:bomber/Api/Twin', password: 'demo-twin-b');
    addEntry(f, 'Box', password: 'pw-older', fields: {'Notes': 'n-older'});
    final grants = TomSecretsGrantsGroup(f);
    grants.write('bomber', TomSecretsSignedKind.grant, {
      'id': 'g-stripe',
      'host': 'bomber',
      'subject': 'exe /usr/bin/demo-app',
      'secret': 'stripe.key',
      'decision': 'allow',
      'created': '2026-11-01T00:00:00Z',
      'lastUsed': demoLastUsed.toIso8601String(),
    });
    grants.write('bomber', TomSecretsSignedKind.grant, {
      'id': 'g-never',
      'host': 'bomber',
      'subject': 'exe /usr/bin/other',
      'secret': 'all',
      'decision': 'never',
      'created': '2026-11-01T00:00:00Z',
    });
    grants.write('ci', TomSecretsSignedKind.grant, {
      'id': 'g-revoked',
      'host': 'ci',
      'subject': 'exe /usr/bin/ci',
      'secret': 'all',
      'decision': 'allow',
      'created': '2026-11-01T00:00:00Z',
    });
    grants.write('ci', TomSecretsSignedKind.revocation, {
      'host': 'ci',
      'grantId': 'g-revoked',
      'revoked': '2026-11-02T00:00:00Z',
    });
  });
  final prod = await demoVault('prod', 'prod-demo-pw', (f) {
    TomSecretsMetadata(
      store: 'prod',
      kind: TomSecretsVaultKind.system,
      binding: const {'env': 'prod'},
    ).writeTo(f);
    addEntry(
      f,
      'Stripe',
      password: 'demo-stripe-prod',
      fields: {'tsm.key': 'stripe.key'},
    );
  });
  final staging = await demoVault('staging', 'staging-demo-pw', (f) {
    TomSecretsMetadata(
      store: 'staging',
      kind: TomSecretsVaultKind.system,
      binding: const {'env': 'staging'},
    ).writeTo(f);
    addEntry(
      f,
      'Stripe',
      password: 'demo-stripe-staging',
      fields: {'tsm.key': 'stripe.key'},
    );
  });
  return (
    stores: [
      FakeStore('primary', demoPassword, await _withConflict(primary)),
      FakeStore('prod', 'prod-demo-pw', prod),
    ],
    staging: FakeStore('staging', 'staging-demo-pw', staging),
  );
}

/// [stored] with `Box` changed (Password, Notes) and a conflict record
/// naming the older version, as a merge leaves it.
Future<Uint8List> _withConflict(Uint8List stored) async {
  final credentials = tomSecretsVaultCredentials(password: demoPassword);
  final edited = await KdbxFormat().read(stored, credentials);
  KdbxEntry box(KdbxFile f) =>
      f.body.rootGroup.getAllEntries().firstWhere((e) => e.label == 'Box');
  box(edited)
    ..setString(KdbxKeyCommon.PASSWORD, ProtectedValue.fromString('pw-newer'))
    ..setString(KdbxKeyCommon.NOTES, PlainValue('n-newer'));
  // Read back, so the record names the history version's stored time.
  final file = await KdbxFormat().read(await edited.save(), credentials);
  final entry = box(file);
  entry.customData[tomSecretsConflictKey] = jsonEncode([
    TomSecretsEntryConflict(
      entryUuid: entry.uuid.uuid,
      fields: const ['field:Notes', 'field:Password'],
      loserModified: entry.history.last.times.lastModificationTime.get()!,
      at: DateTime.utc(2026, 11, 13),
    ).toJson(),
  ]);
  return file.save();
}

/// mDNS on one in-memory network: what is advertised is browsed.
final class FakePairingDiscovery implements TomSecretsPairingDiscovery {
  /// The adverts on the network.
  final List<TomSecretsPairingAdvert> adverts = [];

  /// How often [browse] ran.
  int browsed = 0;

  @override
  Future<TomSecretsPairingAdvertising> advertise(
    TomSecretsPairingAdvert advert,
  ) async {
    adverts.add(advert);
    return _FakeAdvertising(() => adverts.remove(advert));
  }

  @override
  Future<List<TomSecretsPairingAdvert>> browse({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    browsed++;
    return List.of(adverts);
  }
}

final class _FakeAdvertising implements TomSecretsPairingAdvertising {
  _FakeAdvertising(this._stop);

  final void Function() _stop;

  @override
  Future<void> stop() async => _stop();
}
