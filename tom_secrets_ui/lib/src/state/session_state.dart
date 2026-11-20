// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// `SessionState` of part-app's State: the vaults the app has open for
/// editing (the copies the service holds, protocol.md 6.4), the search index,
/// the selection and the view switches. Locking disposes all of it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import 'conflicts.dart';
import 'emergency_sheet.dart';
import 'import_model.dart';
import 'new_vault.dart';
import 'overlays.dart';
import 'proposals.dart';
import 'rotation.dart';
import 'service_connection.dart';
import 'shares.dart';

/// A vault open in the app's memory.
final class TomSecretsOpenVault {
  TomSecretsOpenVault._({
    required this.store,
    required this.location,
    required this.revision,
    required this.file,
    required this.outerKey,
    required this.cipher,
    this.previousOuterKey,
  });

  /// The store's name.
  final String store;

  /// Its locator.
  final String location;

  /// The revision it was read at: a save names it as `baseRevision`.
  String revision;

  /// The opened file.
  KdbxFile file;

  /// The repository's outer key of a `.tsmx` file (base64), or null; a
  /// rotation sets the new one before the re-keyed save.
  String? outerKey;

  /// The outer cipher of a `.tsmx` file, kept by every save, or null; a
  /// rotation may set another.
  TomSecretsOuterCipher? cipher;

  /// **[C]** During a guided rotation's migration period the old repository
  /// key the `.tsmx` file keeps a slot for (base64): every save writes a
  /// slot for it after the new key's.
  String? previousOuterKey;

  /// The repository keys a save writes slots for.
  String? get writtenOuterKeys =>
      tomSecretsJoinOuterKeys([outerKey, previousOuterKey]);
}

/// An entry by its store and UUID.
@immutable
final class TomSecretsEntryRef {
  /// The entry [uuid] of [store].
  const TomSecretsEntryRef(this.store, this.uuid);

  /// The store.
  final String store;

  /// The entry's UUID.
  final KdbxUuid uuid;

  @override
  bool operator ==(Object other) =>
      other is TomSecretsEntryRef && other.store == store && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(store, uuid);

  @override
  String toString() => '$store/~$uuid';
}

/// An entry as the lists show it.
final class TomSecretsEntryView {
  TomSecretsEntryView._({
    required this.ref,
    required this.entry,
    required this.groups,
    required this.overlays,
    required this.inRecycleBin,
  });

  /// Which entry.
  final TomSecretsEntryRef ref;

  /// The entry.
  final KdbxEntry entry;

  /// The names of its groups below the root, outermost first.
  final List<String> groups;

  /// How many overlays (`@host:…/…` copies) it has.
  final int overlays;

  /// Whether it is in the recycle bin.
  final bool inRecycleBin;

  /// The title.
  String get title => entry.label ?? '';

  /// The user name.
  String get userName =>
      entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';

  /// The URL.
  String get url => entry.getString(KdbxKeyCommon.URL)?.getText() ?? '';

  /// The `tsm.key`, or null.
  String? get key => entry.getString(TomSecretsEntryFields.key)?.getText();

  /// Its type (`tsm.type`).
  TomSecretsEntryType get type => TomSecretsEntryType.of(
    entry.getString(TomSecretsEntryFields.type)?.getText(),
  );

  /// Its tags.
  List<String> get tags => tomSecretsTagsOf(entry);

  /// When it was last modified.
  DateTime? get modified => entry.times.lastModificationTime.get();

  /// When it expires, or null.
  DateTime? get expires =>
      entry.times.expires.get() == true ? entry.times.expiryTime.get() : null;

  /// Whether it carries an unsettled conflict record (`tsm.conflict`).
  bool get hasConflict => tomSecretsConflictsOf(entry).isNotEmpty;

  /// The text the search matches: title, user name, URL, key, tags, notes
  /// and the group path; never a protected value.
  String get searchText => [
    title,
    userName,
    url,
    key ?? '',
    tags.join(' '),
    entry.getString(KdbxKeyCommon.NOTES)?.getText() ?? '',
    groups.join('/'),
  ].join('\n').toLowerCase();
}

/// The tags of [entry].
List<String> tomSecretsTagsOf(KdbxEntry entry) => (entry.tags.get() ?? '')
    .split(';')
    .map((t) => t.trim())
    .where((t) => t.isNotEmpty)
    .toList();

/// Whether [name] is an overlay group (`@host:server1`, part-structure).
bool tomSecretsIsOverlayGroup(String name) => name.startsWith('@');

/// The preference keys the session keeps per device.
abstract final class TomSecretsPreferenceKeys {
  /// `list` or `tree` (BP-24).
  static const view = 'view.layout';

  /// `aware` or `uniform` (BP-25).
  static const vaults = 'view.vaults';
}

/// A vault the primary lists that this machine does not serve, by its store
/// name and locator (`vaultKeySet.unserved`, protocol.md 6.4): opened for
/// editing on request, never served (part-app, Environments, BP-15).
typedef TomSecretsUnservedVault = ({String store, String location});

/// A vault that could not be opened for editing, with why.
final class TomSecretsVaultFailure {
  /// [store] failed with [message].
  const TomSecretsVaultFailure(this.store, this.message);

  /// The store.
  final String store;

  /// Why, for the user.
  final String message;
}

/// The open vaults, the index, the selection and the view switches.
class TomSecretsSession extends ChangeNotifier {
  /// A session over [connection], keeping its view switches in
  /// [preferences].
  TomSecretsSession(
    this.connection,
    this.preferences, {
    this.systemVaultsReadOnly = false,
  }) {
    _listView = preferences.read(TomSecretsPreferenceKeys.view) == 'list';
    _vaultAware =
        preferences.read(TomSecretsPreferenceKeys.vaults) != 'uniform';
    _events = connection.events.listen(_onEvent);
    connection.addListener(_onConnection);
  }

  /// The admin connection.
  final TomSecretsServiceConnection connection;

  /// The device's preferences.
  final TomSecretsPreferences preferences;

  /// Whether system vaults are read-only on this device (mobile, BP-40):
  /// shown with their keys and overlays, never edited.
  final bool systemVaultsReadOnly;

  late final StreamSubscription<Map<String, Object?>> _events;
  final Map<String, TomSecretsOpenVault> _vaults = {};
  final List<TomSecretsVaultFailure> _failures = [];
  List<TomSecretsEntryView> _index = const [];
  bool _loading = false;
  bool _listView = false;
  bool _vaultAware = true;
  TomSecretsResolutionModel? _resolution;
  final Map<String, TomSecretsOpenVault> _editOnly = {};
  List<TomSecretsUnservedVault> _unserved = const [];
  String _query = '';
  String? _filterTag;
  TomSecretsEntryType? _filterType;
  String? _filterStore;
  String? _selectedStore;
  KdbxUuid? _selectedGroup;
  TomSecretsEntryRef? _selectedEntry;
  final Set<TomSecretsEntryRef> _marked = {};
  TomSecretsEntryRef? _changedElsewhere;
  final Set<String> _ownSaves = {};

  /// The open vaults, the primary first.
  List<TomSecretsOpenVault> get vaults => _vaults.values.toList();

  /// The vault of [store], or null.
  TomSecretsOpenVault? vault(String store) => _vaults[store];

  /// The vaults that could not be opened.
  List<TomSecretsVaultFailure> get failures => List.unmodifiable(_failures);

  /// Whether the vaults are being opened.
  bool get loading => _loading;

  /// Whether the list view (else the tree view) is shown (BP-24).
  bool get listView => _listView;
  set listView(bool value) {
    _listView = value;
    unawaited(
      preferences.write(TomSecretsPreferenceKeys.view, value ? 'list' : 'tree'),
    );
    notifyListeners();
  }

  /// Whether the vault-aware view (else the uniform one) is shown (BP-25):
  /// a system vault's entries show their key, overlays, bindings and
  /// readers; a personal or shared vault's their logins, URLs and TOTP.
  bool get vaultAware => _vaultAware;
  set vaultAware(bool value) {
    _vaultAware = value;
    unawaited(
      preferences.write(
        TomSecretsPreferenceKeys.vaults,
        value ? 'aware' : 'uniform',
      ),
    );
    notifyListeners();
  }

  /// The open vaults as the resolver sees them, built again after every
  /// change.
  TomSecretsResolutionModel get resolution =>
      _resolution ??= TomSecretsResolutionModel.build([
        for (final v in _vaults.values) (store: v.store, file: v.file),
      ]);

  /// The kind of [store]'s vault (its metadata's `tsm.kind`).
  TomSecretsVaultKind kindOf(String store) =>
      resolution.store(store)?.metadata.kind ?? TomSecretsVaultKind.personal;

  /// The indexed form of [ref] (its path, bindings and key), or null.
  TomSecretsIndexedEntry? indexedOf(TomSecretsEntryRef ref) =>
      resolution.indexed(ref.store, ref.uuid);

  /// Every unsettled conflict of the open vaults, one row per attribute.
  List<TomSecretsConflictRow> get conflictRows => [
    for (final v in _vaults.values) ...tomSecretsConflictRows(v.store, v.file),
  ];

  /// Writes [resolution] of [row] into its entry, takes the attribute off
  /// the conflict record (the record goes with its last one) and saves.
  Future<void> settleConflict(
    TomSecretsConflictRow row,
    TomSecretsConflictValue? resolution,
  ) => updateEntry(row.ref, (entry) {
    if (row.attribute != 'group') {
      tomSecretsWriteAttribute(entry, row.attribute, resolution);
    }
    tomSecretsSettleAttribute(entry, row.attribute);
  });

  /// A new overlay of [base] bound to [dimension] = [value]: a copy of the
  /// shared entry at `@<dimension>:<value>/<groups>/<title>` (the root
  /// placement, part-structure), saved; answers it.
  Future<TomSecretsEntryRef> createOverlay(
    TomSecretsEntryRef base,
    String dimension,
    String value,
  ) async {
    final indexed = indexedOf(base);
    final shared = entryOf(base);
    if (indexed == null || shared == null) {
      throw StateError('$base is not open');
    }
    final file = _vaults[base.store]!.file;
    var group = file.body.rootGroup;
    for (final name in [
      '$tomSecretsOverlayPrefix$dimension:$value',
      ...indexed.path.sublist(0, indexed.path.length - 1),
    ]) {
      group =
          group.groups.where((g) => g.name.get() == name).firstOrNull ??
          file.createGroup(parent: group, name: name);
    }
    final overlay = KdbxEntry.create(file, group);
    for (final MapEntry(:key, :value) in shared.stringEntries) {
      overlay.setString(key, switch (value) {
        final ProtectedValue p => ProtectedValue.fromString(p.getText()),
        _ => value,
      });
    }
    for (final MapEntry(:key, :value) in shared.binaryEntries) {
      overlay.createBinary(
        isProtected: value.isProtected,
        name: key.key,
        bytes: value.value,
      );
    }
    overlay.tags.set(shared.tags.get());
    overlay.times.expires.set(shared.times.expires.get());
    if (shared.times.expiryTime.get() case final at?) {
      overlay.times.expiryTime.set(at);
    }
    group.addEntry(overlay);
    await save(base.store);
    return TomSecretsEntryRef(base.store, overlay.uuid);
  }

  /// Sets [field] of [ref] to [text] (kept protected when it was, or when
  /// it is the password) and saves.
  Future<void> setField(TomSecretsEntryRef ref, String field, String text) =>
      updateEntry(ref, (entry) {
        final key = KdbxKey(field);
        final protected =
            entry.getString(key) is ProtectedValue ||
            key == KdbxKeyCommon.PASSWORD;
        entry.setString(
          key,
          protected ? ProtectedValue.fromString(text) : PlainValue(text),
        );
      });

  /// Imports [source] (part-password-manager, Import): each source vault
  /// into its [mappings] entry by vault id (default the first vault, group
  /// `<source>/<vault name>`), archived items only with [includeArchived].
  /// With [dryRun] nothing changes and the report is the preview; else the
  /// vaults written are saved through the service, and when a save is
  /// refused every vault is read again (the import is not half kept) and
  /// the admin error is thrown.
  Future<TomSecretsImportReport> importExport(
    TomSecretsImportSource source, {
    required Map<String, TomSecretsImportMapping> mappings,
    bool includeArchived = false,
    bool dryRun = false,
  }) async {
    final first = _vaults.values.firstOrNull;
    if (first == null) throw StateError('no vault is open');
    final targets = <String, TomSecretsImportTarget>{};
    final touched = <String>{};
    for (final v in source.vaults) {
      final m = mappings[v.id];
      final store = m?.store ?? first.store;
      final vault = _vaults[store];
      if (vault == null) throw StateError('$store is not open');
      targets[v.id] = TomSecretsImportTarget(
        vault.file,
        m?.group ?? [source.displayName, v.name],
      );
      touched.add(store);
    }
    final report = tomSecretsImport(
      source,
      file: first.file,
      targets: targets,
      includeArchived: includeArchived,
      dryRun: dryRun,
    );
    if (dryRun) return report;
    try {
      for (final store in touched) {
        await save(store);
      }
    } on TomSecretsAdminException {
      await load();
      rethrow;
    }
    return report;
  }

  /// Imports the KDBX file [source] into [store] as a new group [name]
  /// under the group path [parent] (part-password-manager, KeePass) and
  /// saves the vault; a refused save reads every vault again and throws.
  Future<TomSecretsKdbxImportResult> importKdbxAsGroup(
    KdbxFile source, {
    required String store,
    required String name,
    List<String> parent = const [],
  }) async {
    final vault = _vaults[store];
    if (vault == null) throw StateError('$store is not open');
    final result = tomSecretsImportKdbxAsGroup(
      vault.file,
      source,
      name: name,
      parent: parent,
    );
    await _saveImported(store);
    return result;
  }

  /// Merges the KDBX file [source], a copy of [store]'s vault edited
  /// elsewhere, into it entry by entry and saves the vault. Throws
  /// `TomMergeRefusedException` for a file of another vault (nothing
  /// changes).
  Future<TomSecretsMergeResult> importKdbxMerged(
    KdbxFile source, {
    required String store,
  }) async {
    final vault = _vaults[store];
    if (vault == null) throw StateError('$store is not open');
    final result = tomSecretsImportKdbxMerged(vault.file, source);
    await _saveImported(store);
    return result;
  }

  Future<void> _saveImported(String store) async {
    try {
      await save(store);
    } on TomSecretsAdminException {
      await load();
      rethrow;
    }
  }

  /// Sets when the key file and repository key of [store] are due for
  /// rotation (DP-85): the primary's `tsm.keys-due`, else the Expires of the
  /// vault's entry in the primary; saves the primary. The service reminds
  /// of the new date after its next refresh.
  Future<void> setVaultKeysDue(String store, DateTime due) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final at = due.toUtc();
    if (store == primary.store) {
      final m = TomSecretsMetadata.read(primary.file);
      TomSecretsMetadata(
        format: m.format,
        store: m.store,
        kind: m.kind,
        purpose: m.purpose,
        binding: m.binding,
        configYaml: m.configYaml,
        keysDue: at,
        sshConfirm: m.sshConfirm,
        githubAppClientId: m.githubAppClientId,
      ).writeTo(primary.file);
    } else {
      final list = TomSecretsPrimaryVaults(primary.file);
      final keys = list.byName(store);
      if (keys == null) throw StateError('the primary lists no $store');
      // copyWith keeps a guided rotation's next and previous keys.
      list.put(keys.copyWith(expires: at));
    }
    await save(primary.store);
  }

  /// Rotates the keys of [store] by hand (part-key-rotation) as [rotation]
  /// says, through the service (DP-13):
  ///
  /// 1. makes the new keys: a master password given, a new key file, a new
  ///    repository key (for a `.tsmx` vault: every vault of the same
  ///    repository under the same key, and the primary when it is one of
  ///    them, is re-encrypted with a single slot for the new key);
  /// 2. writes them into the primary: each affected vault's entry with
  ///    Expires = now + `vaultKeyAgeMonths`, for the primary its metadata's
  ///    `tsm.keys-due` = now + `primaryKeyAgeMonths`; saves the primary
  ///    (re-keyed, carrying its new keys, when its own keys change);
  /// 3. saves every affected vault re-keyed (the service takes the keys from
  ///    the primary);
  /// 4. cuts the history of every `github:` repository written (retention
  ///    0), so no commit keeps a file under the old keys.
  ///
  /// Answers the new key material for the user's recovery copies. Throws
  /// [ArgumentError] for a rotation that changes nothing or leaves a vault
  /// with neither a password nor a key file, or a new repository key for a
  /// vault without outer encryption; `TomSecretsAdminException` when a save
  /// is refused. A failure after the primary was saved leaves the vaults
  /// not yet re-keyed served with their old keys: [pendingRotations] names
  /// them and [finishRotations] makes their re-keyed saves.
  Future<TomSecretsRotated> rotateKeys(
    String store,
    TomSecretsKeyChanges rotation, {
    DateTime? now,
  }) async {
    if (rotation.isEmpty) {
      throw ArgumentError.value(rotation, 'rotation', 'changes nothing');
    }
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final guided = guidedRotationOf(store);
    if (guided != null) {
      // Its keys are the guided rotation's until it finishes or is
      // cancelled (part-key-rotation).
      throw TomSecretsRotationException(
        'a guided rotation of ${guided.target} runs: finish or cancel it '
        'first',
        rotation: guided,
      );
    }
    final at = (now ?? DateTime.now()).toUtc();
    final list = TomSecretsPrimaryVaults(primary.file);
    final isPrimary = store == primary.store;
    final listed = isPrimary ? null : list.byName(store);
    if (!isPrimary && listed == null) {
      throw StateError('the primary lists no $store');
    }
    final held = await _heldKeys([primary.store, if (!isPrimary) store]);
    final old = held[store]!;
    final location = isPrimary ? primary.location : listed!.locator;

    // 1. The new keys. After an OS unlock the service holds the primary's
    // composite key, not its password: a rotation that keeps the password
    // keeps the composite key, unless the key file changes, which needs the
    // password itself.
    final password = rotation.password ?? old['password'] as String?;
    final keptComposite =
        isPrimary && rotation.password == null && old['compositeKey'] is String;
    if (keptComposite && rotation.keyFile != TomSecretsKeyFileChange.keep) {
      throw StateError(
        'Changing the key file keeps the master password, which this '
        'unlock (the OS unlock) does not hold: lock, unlock with the master '
        'password, and rotate again.',
      );
    }
    final oldKeyFile = old['keyFile'] is String
        ? base64.decode(old['keyFile']! as String)
        : null;
    final newKeyFile = rotation.keyFile == TomSecretsKeyFileChange.renew
        ? TomSecretsKeyFile.generate().toBytes()
        : null;
    final keyFile = switch (rotation.keyFile) {
      TomSecretsKeyFileChange.keep => oldKeyFile,
      TomSecretsKeyFileChange.renew => newKeyFile,
      TomSecretsKeyFileChange.remove => null,
    };
    if (!keptComposite &&
        (password == null || password.isEmpty) &&
        keyFile == null) {
      throw ArgumentError('a vault needs a master password or a key file');
    }
    final oldOuter = old['outerKey'] as String?;
    final outer = location.endsWith(tomSecretsOuterSuffix);
    if ((rotation.newRepositoryKey || rotation.cipher != null) &&
        (!outer || oldOuter == null)) {
      throw ArgumentError('$store is not outer encrypted');
    }
    final newOuter = rotation.newRepositoryKey
        ? TomSecretsRepositoryKey.generate().toBase64()
        : null;

    // The vaults a new repository key re-encrypts: every one of the same
    // repository under the same key.
    final repository = tomSecretsRepositoryOf(location);
    final others = <String>[
      if (rotation.newRepositoryKey)
        for (final v in list.list())
          if (v.name != store &&
              v.outerKey == oldOuter &&
              tomSecretsRepositoryOf(v.locator) == repository)
            v.name,
    ];
    final primaryAffected =
        isPrimary ||
        (rotation.newRepositoryKey &&
            held[primary.store]!['outerKey'] == oldOuter &&
            tomSecretsRepositoryOf(primary.location) == repository);
    final further = [if (!isPrimary) store, ...others];
    final opened = <String>[];
    for (final name in further) {
      if (_vaultOf(name) == null) {
        await openUnserved(name);
        opened.add(name);
      }
    }

    // 2. Into the primary.
    final device = await _deviceSettings();
    for (final name in further) {
      final entry = list.byName(name)!;
      final target = name == store;
      list.put(
        TomSecretsVaultKeys(
          name: entry.name,
          locator: entry.locator,
          password: target ? password : entry.password,
          keyFile: target ? keyFile : entry.keyFile,
          outerKey: newOuter ?? entry.outerKey,
          githubToken: entry.githubToken,
          githubTokenExpires: entry.githubTokenExpires,
          expires: tomSecretsAddMonths(at, device.vaultKeyAgeMonths),
        ),
      );
    }
    Map<String, Object?>? primaryKeys;
    if (primaryAffected) {
      final m = TomSecretsMetadata.read(primary.file);
      TomSecretsMetadata(
        format: m.format,
        store: m.store,
        kind: m.kind,
        purpose: m.purpose,
        binding: m.binding,
        configYaml: m.configYaml,
        keysDue: tomSecretsAddMonths(at, device.primaryKeyAgeMonths),
        sshConfirm: m.sshConfirm,
        githubAppClientId: m.githubAppClientId,
      ).writeTo(primary.file);
      final keys = held[primary.store]!;
      // The primary's own keys unchanged (another vault rotated, or only its
      // repository key): its held keys, a composite key included.
      final unchanged = !isPrimary || keptComposite;
      if (unchanged) {
        primary.file.credentials = _credentialsOf(keys);
      } else {
        primary.file.credentials = tomSecretsVaultCredentials(
          password: password,
          keyFile: keyFile,
        );
      }
      if (newOuter != null) primary.outerKey = newOuter;
      if (rotation.cipher != null) primary.cipher = rotation.cipher;
      primaryKeys = {
        ...(unchanged
            ? _heldKeysWire(keys)
            : {
                'password': password ?? '',
                if (keyFile != null) 'keyFile': base64.encode(keyFile),
              }),
        'outerKey': ?primary.outerKey,
      };
    }
    await save(primary.store, keys: primaryKeys);

    // 3. The vaults, re-keyed.
    final rekeyed = [if (primaryAffected) primary.store];
    for (final name in further) {
      final vault = _vaultOf(name)!;
      final keys = list.byName(name)!;
      vault.file.credentials = tomSecretsVaultCredentials(
        password: keys.password,
        keyFile: keys.keyFile == null
            ? null
            : Uint8List.fromList(keys.keyFile!),
      );
      if (newOuter != null) vault.outerKey = newOuter;
      if (rotation.cipher != null) vault.cipher = rotation.cipher;
      await save(name);
      rekeyed.add(name);
    }
    for (final name in opened) {
      closeEditOnly(name);
    }

    // 4. The history of the repositories written.
    final compacted = <String>[];
    final failures = <String, String>{};
    final repositories = {
      for (final name in rekeyed)
        ?tomSecretsGitHubRepositoryOf(
          name == primary.store ? primary.location : list.byName(name)!.locator,
        ),
    };
    for (final slug in repositories) {
      try {
        await connection.request('compact', {
          'repository': slug,
          'retentionDays': 0,
        });
        compacted.add(slug);
      } on TomSecretsAdminException catch (e) {
        failures[slug] = e.message;
      }
    }
    return TomSecretsRotated(
      store: store,
      primary: primary.store,
      rekeyed: rekeyed,
      keyFile: newKeyFile,
      repositoryKey: newOuter,
      compacted: compacted,
      compactFailures: failures,
    );
  }

  /// The emergency sheet of the primary (BP-37) as the keys are now: the
  /// primary's key file and repository key as the service holds them, every
  /// further vault the primary lists with its key file and repository key,
  /// and the outer cipher of each file open here. No password is read into
  /// it.
  Future<TomSecretsEmergencySheet> emergencySheet() async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final keys = (await _heldKeys([primary.store]))[primary.store]!;
    final keyFile = keys['keyFile'];
    final listed = TomSecretsPrimaryVaults(primary.file).list();
    return TomSecretsEmergencySheet.of(
      primaryName: primary.store,
      primaryLocator: primary.location,
      primaryKeyFile: keyFile is String ? base64.decode(keyFile) : null,
      primaryOuterKey: keys['outerKey'] as String?,
      primaryCipher: primary.cipher,
      listed: listed,
      ciphers: {for (final v in listed) v.name: _vaultOf(v.name)?.cipher},
    );
  }

  /// The repository keys the vaults in [store]'s repository already use
  /// (the primary's included), each with the vaults under it: what adding
  /// the outer encryption to [store] may take instead of a new key.
  Future<List<TomSecretsKnownRepositoryKey>> repositoryKeysFor(
    String store,
  ) async {
    final vault = _vaultOf(store);
    if (vault == null) return const [];
    return repositoryKeysAt(vault.location, except: store);
  }

  /// The repository keys the vaults in [location]'s repository already use
  /// (the primary's included, [except] left out), each with the vaults
  /// under it: what a vault outer encrypted there may take instead of a new
  /// key.
  Future<List<TomSecretsKnownRepositoryKey>> repositoryKeysAt(
    String location, {
    String? except,
  }) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) return const [];
    final store = except;
    final repository = tomSecretsRepositoryOf(location);
    final byKey = <String, List<String>>{};
    void take(String name, String locator, String? key) {
      if (key == null || name == store) return;
      if (tomSecretsRepositoryOf(locator) != repository) return;
      (byKey[key] ??= []).add(name);
    }

    final held = (await _heldKeys([primary.store]))[primary.store]!;
    take(primary.store, primary.location, held['outerKey'] as String?);
    for (final v in TomSecretsPrimaryVaults(primary.file).list()) {
      take(v.name, v.locator, v.outerKey);
    }
    return [
      for (final MapEntry(:key, :value) in byKey.entries)
        (
          keyId: TomSecretsRepositoryKey.fromBase64(key).keyIdHex,
          key: key,
          vaults: value,
        ),
    ];
  }

  /// Adds ([add]) or removes the outer encryption of [store] through the
  /// service (`vault.move`, protocol.md 6.4): the vault moves to its locator
  /// with `.kdbx.tsmx` added or removed, encrypted under [outerKey] (a key
  /// another vault of the repository uses, [repositoryKeysFor]) or a new
  /// repository key, with [cipher]; its other keys stay. Then the vaults are
  /// read again and the `github:` repository's history is cut (retention
  /// 0), so no commit keeps the file without the outer layer. Throws
  /// [StateError] for a vault not served here and [ArgumentError] when it
  /// already is as asked; `TomSecretsAdminException` when the service
  /// refuses.
  Future<TomSecretsOuterMoved> moveOuter(
    String store, {
    required bool add,
    String? outerKey,
    TomSecretsOuterCipher cipher = TomSecretsOuterCipher.xchacha20Poly1305,
  }) async {
    final vault = _vaults[store];
    if (vault == null) {
      throw StateError('$store is not served on this machine');
    }
    final from = vault.location;
    if (add == from.endsWith(tomSecretsOuterSuffix)) {
      throw ArgumentError(
        add
            ? '$store is outer encrypted already'
            : '$store has no outer '
                  'encryption',
      );
    }
    final to = add
        ? '$from$tomSecretsOuterSuffix'
        : from.substring(0, from.length - tomSecretsOuterSuffix.length);
    final key = add
        ? (outerKey ?? TomSecretsRepositoryKey.generate().toBase64())
        : null;
    final held = (await _heldKeys([store]))[store]!;
    final bytes = await tomSecretsEncodeStored(
      to,
      vault.file,
      outerKey: key,
      cipher: cipher,
    );
    _ownSaves.add(store);
    try {
      await connection.request('vault.move', {
        'store': store,
        'location': to,
        'bytes': base64.encode(bytes),
        'baseRevision': vault.revision,
        'keys': {..._heldKeysWire(held), 'outerKey': ?key},
      });
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      _ownSaves.remove(store);
    }
    await load();
    final compacted = <String>[];
    final failures = <String, String>{};
    final slug = tomSecretsGitHubRepositoryOf(to);
    if (slug != null) {
      try {
        await connection.request('compact', {
          'repository': slug,
          'retentionDays': 0,
        });
        compacted.add(slug);
      } on TomSecretsAdminException catch (e) {
        failures[slug] = e.message;
      }
    }
    return TomSecretsOuterMoved(
      store: store,
      from: from,
      to: to,
      repositoryKey: add && outerKey == null ? key : null,
      reusedKeyId: outerKey == null
          ? null
          : TomSecretsRepositoryKey.fromBase64(outerKey).keyIdHex,
      compacted: compacted,
      compactFailures: failures,
    );
  }

  /// Makes the new, empty vault file of [createVault]: `tomSecretsNewVault`
  /// with its default Argon2id; a test passes a lighter one.
  @visibleForTesting
  KdbxFile Function(String password, Uint8List? keyFile, String name)
  newVaultFile = (password, keyFile, name) => tomSecretsNewVault(
    tomSecretsVaultCredentials(password: password, keyFile: keyFile),
    name,
  );

  /// Creates the further vault [spec] names beside the primary through the
  /// service (`vault.create`, protocol.md 6.4): a new, empty vault (KDBX
  /// 4.1, Argon2id, through [newVaultFile]) with its metadata (the store name, its
  /// kind, a system vault's environment binding, the purpose), under its
  /// master password (given, or generated) and key file (none, the
  /// primary's, or a new one), and for an outer-encrypted vault under the
  /// repository key chosen or a new one. The service writes it where it
  /// lives and lists it in the primary with its keys, due for rotation after
  /// `vaultKeyAgeMonths`; then the vaults are read again. Answers the new key
  /// material for the user's recovery copies. Throws [ArgumentError] for a
  /// name in use or a place that cannot be named, [StateError] when no
  /// primary is open, `TomSecretsAdminException` when the service refuses.
  Future<TomSecretsVaultCreated> createVault(
    TomSecretsNewVaultSpec spec, {
    DateTime? now,
  }) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final name = spec.name;
    final taken = {
      ..._vaults.keys,
      for (final u in _unserved) u.store,
      for (final v in TomSecretsPrimaryVaults(primary.file).list()) v.name,
    };
    if (taken.contains(name)) {
      throw ArgumentError.value(name, 'name', 'a vault $name exists already');
    }
    final location = tomSecretsNewVaultLocation(spec, primary.location);
    final held = (await _heldKeys([primary.store]))[primary.store]!;
    final primaryKeyFile = held['keyFile'] as String?;
    if (spec.keyFile == TomSecretsNewKeyFile.primary &&
        primaryKeyFile == null) {
      throw ArgumentError('the primary has no key file');
    }
    final generated = spec.password == null || spec.password!.isEmpty;
    final password = generated
        ? TomSecretsPasswordGenerator().generate(
            TomSecretsPasswordPolicy(length: 32),
          )
        : spec.password!;
    final newKeyFile = spec.keyFile == TomSecretsNewKeyFile.generate
        ? TomSecretsKeyFile.generate().toBytes()
        : null;
    final keyFile = switch (spec.keyFile) {
      TomSecretsNewKeyFile.none => null,
      TomSecretsNewKeyFile.primary => base64.decode(primaryKeyFile!),
      TomSecretsNewKeyFile.generate => newKeyFile,
    };
    final newOuter = spec.outer && spec.repositoryKey == null
        ? TomSecretsRepositoryKey.generate().toBase64()
        : null;
    final outerKey = spec.outer ? (spec.repositoryKey ?? newOuter) : null;
    final file = newVaultFile(password, keyFile, name);
    final purpose = spec.purpose?.trim();
    TomSecretsMetadata(
      store: name,
      kind: spec.kind,
      purpose: purpose == null || purpose.isEmpty ? null : purpose,
      binding: spec.binding,
    ).writeTo(file);
    final bytes = await tomSecretsEncodeStored(
      location,
      file,
      outerKey: outerKey,
      cipher: spec.cipher,
    );
    final device = await _deviceSettings();
    final at = (now ?? DateTime.now()).toUtc();
    final token = spec.githubToken?.trim();
    try {
      await connection.request('vault.create', {
        'store': name,
        'location': location,
        'bytes': base64.encode(bytes),
        'keys': {
          'password': password,
          if (keyFile != null) 'keyFile': base64.encode(keyFile),
          'outerKey': ?outerKey,
        },
        if (token != null && token.isNotEmpty) 'githubToken': token,
        'keysDue': tomSecretsAddMonths(
          at,
          device.vaultKeyAgeMonths,
        ).toIso8601String(),
      });
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    await load();
    return TomSecretsVaultCreated(
      store: name,
      location: location,
      keyFile: newKeyFile,
      repositoryKey: newOuter,
      passwordGenerated: generated,
    );
  }

  /// The vaults the primary lists with other keys than the service holds:
  /// a rotation whose re-keyed save failed (or was made elsewhere and not
  /// finished). [finishRotations] completes them.
  Future<List<TomSecretsPendingRotation>> pendingRotations() async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) return const [];
    final listed = TomSecretsPrimaryVaults(primary.file).list();
    if (listed.isEmpty) return const [];
    final held = await _heldKeys([for (final v in listed) v.name]);
    return [
      for (final v in listed)
        if (held[v.name] != null && !_sameKeys(v, held[v.name]!))
          (store: v.name, location: v.locator),
    ];
  }

  /// Saves every vault of [pendingRotations] re-keyed with the keys the
  /// primary lists for it; answers the vaults written.
  Future<List<String>> finishRotations() async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) return const [];
    final list = TomSecretsPrimaryVaults(primary.file);
    final done = <String>[];
    for (final pending in await pendingRotations()) {
      final name = pending.store;
      final opened = _vaultOf(name) == null;
      final vault = _vaultOf(name) ?? await openUnserved(name);
      final keys = list.byName(name)!;
      vault.file.credentials = tomSecretsVaultCredentials(
        password: keys.password,
        keyFile: keys.keyFile == null
            ? null
            : Uint8List.fromList(keys.keyFile!),
      );
      vault.outerKey = keys.outerKey;
      await save(name);
      if (opened) closeEditOnly(name);
      done.add(name);
    }
    return done;
  }

  static bool _sameKeys(TomSecretsVaultKeys listed, Map<String, Object?> held) {
    final keyFile = held['keyFile'];
    final listedKeyFile = listed.keyFile == null
        ? null
        : base64.encode(listed.keyFile!);
    final composite = held['compositeKey'];
    if (composite is String) {
      // Opened with an OS unlock's composite key: the same key when the
      // listed password and key file make it.
      final listedComposite = tomSecretsCompositeKey(
        password: listed.password,
        keyFile: listed.keyFile == null
            ? null
            : Uint8List.fromList(listed.keyFile!),
      );
      return base64.encode(listedComposite) == composite &&
          listed.outerKey == held['outerKey'];
    }
    return listed.password == held['password'] &&
        listed.outerKey == held['outerKey'] &&
        listedKeyFile == keyFile;
  }

  /// The credentials of the keys the service holds (`vaultKeys`): an OS
  /// unlock's `compositeKey` (protocol.md 6.4), else the password and key
  /// file.
  static Credentials _credentialsOf(Map<String, Object?> keys) {
    final composite = keys['compositeKey'];
    final keyFile = keys['keyFile'];
    return tomSecretsVaultCredentials(
      password: keys['password'] as String?,
      keyFile: keyFile is String ? base64.decode(keyFile) : null,
      compositeKey: composite is String ? base64.decode(composite) : null,
    );
  }

  /// The primary's `keys` for `save` and `vault.move` as the service holds
  /// them: after an OS unlock the composite key in place of the password
  /// (protocol.md 6.4), the key file beside it for the keychain.
  static Map<String, Object?> _heldKeysWire(Map<String, Object?> held) =>
      held['compositeKey'] is String
      ? {'compositeKey': held['compositeKey'], 'keyFile': ?held['keyFile']}
      : {
          'password': held['password'] as String? ?? '',
          'keyFile': ?held['keyFile'],
        };

  /// The keys the service holds for [stores] (`vaultKeys`), by store.
  Future<Map<String, Map<String, Object?>>> _heldKeys(
    List<String> stores,
  ) async {
    final set = await connection.request('vaultKeys', {'stores': stores});
    return {
      for (final s in (set['stores'] as List).cast<Map>())
        s['store'] as String: (s['keys'] as Map? ?? const {})
            .cast<String, Object?>(),
    };
  }

  Future<TomSecretsDeviceSettings> _deviceSettings() async {
    final answer = await connection.request('settings.get');
    return TomSecretsDeviceSettings.fromJson(
      (answer['device'] as Map? ?? const {}).cast<String, Object?>(),
    );
  }

  /// The shared configuration's YAML (`tsm.config` in the primary's
  /// metadata entry, BP-43), or null when the primary has none.
  String? get sharedConfigYaml {
    final primary = _vaults.values.firstOrNull;
    return primary == null
        ? null
        : TomSecretsMetadata.read(primary.file).configYaml;
  }

  /// Writes [yaml] as the shared configuration into the primary and saves
  /// it (every device reads it from there). Throws
  /// `TomSecretsConfigException` when it does not read, before anything is
  /// written; an empty text removes it (the built-in dimensions apply).
  Future<void> saveSharedConfig(String yaml) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final text = yaml.trim();
    if (text.isNotEmpty) TomSecretsConfig.parse(text);
    final m = TomSecretsMetadata.read(primary.file);
    TomSecretsMetadata(
      format: m.format,
      store: m.store,
      kind: m.kind,
      purpose: m.purpose,
      binding: m.binding,
      configYaml: text.isEmpty ? null : '$text\n',
      keysDue: m.keysDue,
      sshConfirm: m.sshConfirm,
      githubAppClientId: m.githubAppClientId,
    ).writeTo(primary.file);
    await save(primary.store);
  }

  /// The vaults the primary lists that this machine does not serve.
  List<TomSecretsUnservedVault> get unserved => _unserved;

  /// The vaults not served that are open for editing (Environments), in the
  /// order they were opened. They take no part in the index or resolution.
  List<TomSecretsOpenVault> get editOnly => _editOnly.values.toList();

  /// Whether [store] is a vault not served, open for editing.
  bool isEditOnly(String store) => _editOnly.containsKey(store);

  /// Opens the vault not served [store] for editing through the service:
  /// its keys (`vaultKeys` naming it) and the copy the service reads from its
  /// location (`vaultFile`); its saves go through the service like every
  /// other (`save`). Throws `TomSecretsAdminException` (`needs_unlock`,
  /// `offline`, `token_expired`, `unavailable`, `not_found`).
  Future<TomSecretsOpenVault> openUnserved(String store) async {
    final set = await connection.request('vaultKeys', {
      'stores': [store],
    });
    final s = (set['stores'] as List).cast<Map>().single;
    final vault = await _open(
      store,
      (s['keys'] as Map? ?? const {}).cast<String, Object?>(),
    );
    _editOnly[store] = vault;
    _resolution = null;
    notifyListeners();
    return vault;
  }

  /// Closes the vault not served [store] (its saves are written already).
  void closeEditOnly(String store) {
    _editOnly.remove(store);
    notifyListeners();
  }

  /// The search over every open vault.
  String get query => _query;
  set query(String value) {
    _query = value;
    notifyListeners();
  }

  /// The list view's tag filter.
  String? get filterTag => _filterTag;
  set filterTag(String? value) {
    _filterTag = value;
    notifyListeners();
  }

  /// The list view's type filter.
  TomSecretsEntryType? get filterType => _filterType;
  set filterType(TomSecretsEntryType? value) {
    _filterType = value;
    notifyListeners();
  }

  /// The list view's vault filter.
  String? get filterStore => _filterStore;
  set filterStore(String? value) {
    _filterStore = value;
    notifyListeners();
  }

  /// The tree view's selected vault and group.
  String? get selectedStore => _selectedStore;

  /// The selected group (null: the vault's root).
  KdbxUuid? get selectedGroup => _selectedGroup;

  /// Selects [group] of [store] in the tree view.
  void selectGroup(String store, KdbxUuid? group) {
    _selectedStore = store;
    _selectedGroup = group;
    _marked.clear();
    notifyListeners();
  }

  /// The entry open in the details pane.
  TomSecretsEntryRef? get selectedEntry => _selectedEntry;
  set selectedEntry(TomSecretsEntryRef? value) {
    _selectedEntry = value;
    _changedElsewhere = null;
    notifyListeners();
  }

  /// The entries marked for a multi-select action.
  Set<TomSecretsEntryRef> get marked => Set.unmodifiable(_marked);

  /// Marks or unmarks [ref].
  void toggleMarked(TomSecretsEntryRef ref) {
    if (!_marked.remove(ref)) _marked.add(ref);
    notifyListeners();
  }

  /// Clears the marks.
  void clearMarked() {
    _marked.clear();
    notifyListeners();
  }

  /// The entry open in the editor changed elsewhere (`store_changed`) and
  /// was reloaded: the editor shows a banner.
  TomSecretsEntryRef? get changedElsewhere => _changedElsewhere;

  /// Counts the index's rebuilds: it changes whenever the open vaults or
  /// their entries do (a load, a save, a change elsewhere, the lock).
  int get indexRevision => _indexRevision;
  int _indexRevision = 0;

  /// Every entry of the open vaults outside the overlay groups and the
  /// recycle bin.
  List<TomSecretsEntryView> get index =>
      _index.where((e) => !e.inRecycleBin).toList();

  /// Every tag of the open vaults, sorted.
  List<String> get allTags =>
      ({for (final e in index) ...e.tags}.toList()..sort());

  /// The view of [ref], or null.
  TomSecretsEntryView? view(TomSecretsEntryRef ref) =>
      _index.where((e) => e.ref == ref).firstOrNull;

  /// Whether [store] cannot be saved now (served from its offline copy, so
  /// a save is refused until the store is reachable), with why.
  String? readOnlyReason(String store) {
    if (systemVaultsReadOnly) {
      final file = _vaultOf(store)?.file;
      if (file != null && _isSystem(file)) {
        return 'read-only on this device: a system vault';
      }
    }
    final state = connection.stores[store];
    // A file under a newer repository key than this device holds (a guided
    // rotation's two slots) is read, never written, also while current.
    if (state == null || !(state.isOffline || state.keyChanged)) return null;
    return 'read-only: ${state.offlineReason}';
  }

  static bool _isSystem(KdbxFile file) {
    try {
      return TomSecretsMetadata.read(file).kind == TomSecretsVaultKind.system;
    } on Object {
      return false;
    }
  }

  /// The entries the list view shows: the search, then its filters.
  List<TomSecretsEntryView> get listResults => _search(index).where((e) {
    if (_filterStore != null && e.ref.store != _filterStore) return false;
    if (_filterType != null && e.type != _filterType) return false;
    if (_filterTag != null && !e.tags.contains(_filterTag)) return false;
    return true;
  }).toList();

  /// The entries the tree view's middle pane shows: the selected group's own
  /// entries, or, while a search is typed, the matches in every vault.
  List<TomSecretsEntryView> get groupResults {
    if (_query.trim().isNotEmpty) return _search(index);
    final store = _selectedStore;
    if (store == null) return const [];
    final file = _vaults[store]?.file;
    if (file == null) return const [];
    final group = _selectedGroup == null
        ? file.body.rootGroup
        : _groupOf(file, _selectedGroup!);
    if (group == null) return const [];
    final uuids = {for (final e in group.entries) e.uuid};
    return _index
        .where((e) => e.ref.store == store && uuids.contains(e.ref.uuid))
        .toList();
  }

  List<TomSecretsEntryView> _search(List<TomSecretsEntryView> from) {
    final words = _query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return from;
    return from.where((e) {
      final text = e.searchText;
      return words.every(text.contains);
    }).toList();
  }

  /// Opens every vault the service has open: `vaultKeys`, then `vaultFile`
  /// per store, each opened with its keys in the app's memory.
  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      final set = await connection.request('vaultKeys');
      _vaults.clear();
      _editOnly.clear();
      _failures.clear();
      _unserved = [
        for (final u in (set['unserved'] as List? ?? const []).cast<Map>())
          (store: u['store'] as String, location: u['location'] as String),
      ];
      for (final s in (set['stores'] as List? ?? const []).cast<Map>()) {
        final store = s['store'] as String;
        try {
          _vaults[store] = await _open(
            store,
            (s['keys'] as Map? ?? const {}).cast<String, Object?>(),
          );
        } on Object catch (e) {
          _failures.add(TomSecretsVaultFailure(store, _describe(e)));
        }
      }
      _selectedStore ??= _vaults.keys.firstOrNull;
      _reindex();
    } finally {
      _loading = false;
      notifyListeners();
    }
    await _migrateSshKeys();
    if (!_refreshingSharedKeys) {
      _refreshingSharedKeys = true;
      try {
        sharedKeysTakenUp.addAll(await refreshSharedVaultKeys());
      } on Object {
        // Tried again at the next load; the vault stays as it is.
      } finally {
        _refreshingSharedKeys = false;
      }
    }
    await checkInbox();
  }

  bool _refreshingSharedKeys = false;

  /// The shared vaults whose new keys the session took up from their
  /// recipients file since it started (another member re-keyed them).
  final Set<String> sharedKeysTakenUp = {};

  /// The SSH keys retyped since the session started, by store (the
  /// migration of [load]).
  final Map<String, int> migratedSshKeys = {};

  /// Retypes phase A's SSH keys in every vault that can be written
  /// (part-structure, DP-5): a `note` (or a KeePassXC entry) holding a
  /// private key becomes an `ssh-key` entry with `KeeAgent.settings`, its
  /// old state in the history (`tomSecretsMigrateSshKeys`), and the vault is
  /// saved. Runs at every load and finds nothing once a vault is migrated;
  /// a vault the service refuses to save is left for the next load.
  Future<void> _migrateSshKeys() async {
    for (final vault in _vaults.values.toList()) {
      if (readOnlyReason(vault.store) != null) continue;
      if (tomSecretsSshKeyCandidates(vault.file).isEmpty) continue;
      final migrated = tomSecretsMigrateSshKeys(vault.file);
      try {
        await save(vault.store);
        migratedSshKeys.update(
          vault.store,
          (n) => n + migrated.length,
          ifAbsent: () => migrated.length,
        );
      } on TomSecretsAdminException {
        // Not written: the vault was read again and keeps its notes.
      }
    }
  }

  /// Generates an SSH key (DP-179: [algorithm] Ed25519, or RSA 4096 for a
  /// tool that needs RSA) into the entry [ref], commented with its title, as
  /// the attachment `id_ed25519` or `id_rsa`, and saves it. Answers the
  /// key's type, public key and fingerprint.
  Future<TomSecretsSshKeyInfo> generateSshKey(
    TomSecretsEntryRef ref, {
    TomSecretsSshKeyAlgorithm algorithm = TomSecretsSshKeyAlgorithm.ed25519,
    int rsaBits = 4096,
  }) async {
    final entry = entryOf(ref);
    if (entry == null) throw StateError('$ref is not open');
    final key = await tomSecretsGenerateSshKey(
      algorithm: algorithm,
      comment: entry.label ?? '',
      rsaBits: rsaBits,
    );
    await updateEntry(
      ref,
      (e) => tomSecretsWriteSshKey(
        e,
        attachmentName: algorithm == TomSecretsSshKeyAlgorithm.rsa
            ? 'id_rsa'
            : 'id_ed25519',
        privateKey: key.privateKey,
      ),
    );
    key.privateKey.fillRange(0, key.privateKey.length, 0);
    return key.info;
  }

  /// **[C]** Generates a certificate into the entry [ref] (DP-179): a key on
  /// ECDSA P-384, or RSA 4096 with [algorithm] `rsa`, a self-signed
  /// certificate for [commonName] (and [subjectAlternativeNames]) valid for
  /// [days], typed `certificate` with Expires its notAfter, and saves; a
  /// certificate there before goes to the entry's history. Generated in
  /// another isolate (RSA takes seconds). Answers it, with its CSR.
  Future<TomSecretsGeneratedCertificate> generateCertificate(
    TomSecretsEntryRef ref, {
    required String commonName,
    List<String> subjectAlternativeNames = const [],
    int days = 365,
    TomSecretsCertificateAlgorithm algorithm =
        TomSecretsCertificateAlgorithm.ecdsaP384,
    int rsaBits = 4096,
  }) async {
    if (entryOf(ref) == null) throw StateError('$ref is not open');
    final generated = await Isolate.run(
      () => tomSecretsGenerateCertificate(
        commonName: commonName,
        subjectAlternativeNames: subjectAlternativeNames,
        days: days,
        algorithm: algorithm,
        rsaBits: rsaBits,
      ),
    );
    await updateEntry(
      ref,
      (e) => tomSecretsWriteCertificate(
        e,
        certificatePem: generated.certificatePem,
        privateKeyPem: generated.privateKeyPem,
      ),
    );
    return generated;
  }

  /// **[C]** Takes a certificate file into the entry [ref]: a PEM holding
  /// the certificate (with its chain) and, when there, its private key, or
  /// a PKCS#12 bundle with its [passphrase]; typed `certificate`, Expires
  /// its notAfter (a bundle's is set by hand), and saves. Throws
  /// `TomSecretsCertificateException` for a file that holds no certificate.
  Future<TomSecretsCertificateInfo?> setCertificateFile(
    TomSecretsEntryRef ref,
    Uint8List bytes, {
    String? passphrase,
  }) async {
    if (entryOf(ref) == null) throw StateError('$ref is not open');
    if (tomSecretsIsPkcs12(bytes)) {
      TomSecretsCertificateInfo? info;
      await updateEntry(
        ref,
        (e) => info = tomSecretsWriteCertificate(
          e,
          pkcs12: bytes,
          passphrase: passphrase,
        ),
      );
      return info;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final key = RegExp(
      '-----BEGIN (?:ENCRYPTED |EC |RSA )?PRIVATE KEY-----[\\s\\S]*?'
      '-----END (?:ENCRYPTED |EC |RSA )?PRIVATE KEY-----',
    ).firstMatch(text)?.group(0);
    final certificates = [
      for (final m in RegExp(
        '-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----',
      ).allMatches(text))
        m.group(0)!,
    ].join('\n');
    // Read before anything is written: a file without a certificate is
    // refused and the entry stays as it was.
    TomSecretsCertificateInfo.parse(certificates);
    TomSecretsCertificateInfo? info;
    await updateEntry(
      ref,
      (e) => info = tomSecretsWriteCertificate(
        e,
        certificatePem: certificates,
        privateKeyPem: key,
        passphrase: passphrase,
      ),
    );
    return info;
  }

  /// **[C]** Generates an OpenPGP key into the entry [ref] (DP-179): ECDSA
  /// P-384 with an ECDH subkey, or RSA 4096 with [algorithm] `rsa`, for
  /// [userId], expiring after [expiresAfter] (null: never); its secret key
  /// locked with a generated passphrase kept in `Password`; typed
  /// `pgp-key`, and saves. Generated in another isolate.
  Future<TomSecretsPgpKeyInfo> generatePgpKey(
    TomSecretsEntryRef ref, {
    required String userId,
    TomSecretsPgpKeyAlgorithm algorithm = TomSecretsPgpKeyAlgorithm.ecdsaP384,
    Duration? expiresAfter,
  }) async {
    if (entryOf(ref) == null) throw StateError('$ref is not open');
    final generated = await Isolate.run(
      () => tomSecretsGeneratePgpKey(
        userId: userId,
        algorithm: algorithm,
        expiresAfter: expiresAfter,
      ),
    );
    await updateEntry(
      ref,
      (e) => tomSecretsWritePgpKey(
        e,
        privateArmored: generated.privateArmored,
        publicArmored: generated.publicArmored,
        passphrase: generated.passphrase,
      ),
    );
    return generated.info;
  }

  /// **[C]** Takes an armoured OpenPGP key into the entry [ref]: a secret
  /// key block (its passphrase in [passphrase]) or someone's public key;
  /// typed `pgp-key`, Expires the key's expiry, and saves. A key the
  /// library does not read is kept without its information. Throws
  /// [FormatException] for text that is no OpenPGP key block.
  Future<TomSecretsPgpKeyInfo?> setPgpKeyFile(
    TomSecretsEntryRef ref,
    Uint8List bytes, {
    String? passphrase,
  }) async {
    if (entryOf(ref) == null) throw StateError('$ref is not open');
    final text = utf8.decode(bytes, allowMalformed: true);
    final isPrivate = text.contains('BEGIN PGP PRIVATE KEY BLOCK');
    if (!isPrivate && !text.contains('BEGIN PGP PUBLIC KEY BLOCK')) {
      throw const FormatException('the file holds no armoured OpenPGP key');
    }
    TomSecretsPgpKeyInfo? info;
    await updateEntry(
      ref,
      (e) => info = tomSecretsWritePgpKey(
        e,
        privateArmored: isPrivate ? text : null,
        publicArmored: isPrivate ? null : text,
        passphrase: passphrase,
      ),
    );
    return info;
  }

  /// Sets whether the ssh-agent confirms every signature with the key of
  /// [ref] (KeeAgent's "require confirmation",
  /// `UseConfirmConstraintWhenAdding`, which KeePassXC reads too), and saves.
  Future<void> setSshKeyConfirm(TomSecretsEntryRef ref, bool confirm) =>
      updateEntry(ref, (e) {
        final settings =
            tomSecretsKeeAgentSettingsOf(e) ??
            TomSecretsKeeAgentSettings(
              attachmentName: tomSecretsSshKeyOf(e)?.name,
            );
        tomSecretsWriteKeeAgentSettings(
          e,
          settings.copyWith(useConfirmConstraintWhenAdding: confirm),
        );
      });

  /// Whether the ssh-agent confirms every signature with a key of [store]
  /// (the vault's `tsm.ssh-confirm`).
  bool sshConfirmOf(String store) {
    final vault = _vaults[store];
    return vault != null && TomSecretsMetadata.read(vault.file).sshConfirm;
  }

  /// Sets the vault setting `tsm.ssh-confirm` of [store] (every ssh-agent
  /// signature with a key of the vault is confirmed) and saves the vault.
  Future<void> setVaultSshConfirm(String store, bool confirm) async {
    final vault = _vaults[store];
    if (vault == null) throw StateError('$store is not open');
    TomSecretsMetadata.read(
      vault.file,
    ).copyWith(sshConfirm: confirm).writeTo(vault.file);
    await save(store);
  }

  /// **[C]** The relay whose mailbox the shared vault [store]'s members
  /// use (`tsm.mailbox-relay`, part-relay), or null: the vault's own
  /// repository's inbox folders.
  TomSecretsRelayId? mailboxRelayOf(String store) {
    final vault = _vaults[store];
    if (vault == null) return null;
    try {
      return TomSecretsMetadata.read(vault.file).mailboxRelay;
    } on TomSecretsMetadataException {
      return null;
    }
  }

  /// **[C]** Sets the shared vault [store]'s mailbox relay (null: its own
  /// repository's inbox folders) in its metadata and saves it, so every
  /// member's app reads the same one.
  Future<void> setVaultMailboxRelay(
    String store,
    TomSecretsRelayId? relay,
  ) async {
    final vault = _vaults[store];
    if (vault == null) throw StateError('$store is not open');
    TomSecretsMetadata.read(vault.file)
        .copyWith(mailboxRelay: relay, clearMailboxRelay: relay == null)
        .writeTo(vault.file);
    await save(store);
  }

  /// Takes the private key file [bytes] named [name] into the entry [ref]
  /// as its SSH key and saves it. Throws [FormatException] when the file
  /// holds no private key.
  Future<TomSecretsSshKeyInfo> setSshKeyFile(
    TomSecretsEntryRef ref,
    String name,
    Uint8List bytes,
  ) async {
    final info = TomSecretsSshKeyInfo.parse(bytes);
    if (info == null) {
      throw const FormatException('the file holds no SSH private key');
    }
    await updateEntry(
      ref,
      (e) => tomSecretsWriteSshKey(e, attachmentName: name, privateKey: bytes),
    );
    return info;
  }

  Future<TomSecretsOpenVault> _open(
    String store,
    Map<String, Object?> keys,
  ) async {
    final answer = await connection.request('vaultFile', {'store': store});
    final location = answer['location'] as String;
    final stored = base64.decode(answer['bytes'] as String);
    final outerKey = keys['outerKey'] as String?;
    final previousOuterKey = keys['previousOuterKey'] as String?;
    final file = await tomSecretsDecodeStored(
      location,
      stored,
      _credentialsOf(keys),
      outerKey: tomSecretsJoinOuterKeys([outerKey, previousOuterKey]),
    );
    final cipher = location.endsWith(tomSecretsOuterSuffix)
        ? tomSecretsOuterCipherOf(stored)
        : null;
    stored.fillRange(0, stored.length, 0);
    return TomSecretsOpenVault._(
      store: store,
      location: location,
      revision: answer['revision'] as String,
      file: file,
      outerKey: outerKey,
      cipher: cipher,
      previousOuterKey: previousOuterKey,
    );
  }

  Future<void> _reopen(String store) async {
    final set = await connection.request('vaultKeys', {
      'stores': [store],
    });
    final s = (set['stores'] as List).cast<Map>().single;
    final vault = await _open(
      store,
      (s['keys'] as Map? ?? const {}).cast<String, Object?>(),
    );
    if (_editOnly.containsKey(store)) {
      _editOnly[store] = vault;
    } else {
      _vaults[store] = vault;
    }
  }

  /// The open vault [store], served or open for editing only, or null.
  TomSecretsOpenVault? _vaultOf(String store) =>
      _vaults[store] ?? _editOnly[store];

  /// Saves [store]'s file through the service (protocol.md 6.4) against the
  /// revision it was read at, then reads back what was written. Throws
  /// `TomSecretsAdminException`; on `stale_base` the vault is read again and
  /// the edit has to be made once more.
  ///
  /// [keys] are the primary's new keys when its file is re-keyed (`save`'s
  /// `keys`, protocol.md 6.4).
  Future<void> save(
    String store, {
    Map<String, Object?>? keys,
    Uint8List? recipients,
  }) async {
    final vault = _vaultOf(store);
    if (vault == null) throw StateError('$store is not open');
    final bytes = await tomSecretsEncodeStored(
      vault.location,
      vault.file,
      outerKey: vault.writtenOuterKeys,
      cipher: vault.cipher ?? TomSecretsOuterCipher.xchacha20Poly1305,
    );
    _ownSaves.add(store);
    try {
      await connection.request('save', {
        'store': store,
        'bytes': base64.encode(bytes),
        'baseRevision': vault.revision,
        'keys': ?keys,
        if (recipients != null) 'recipients': base64.encode(recipients),
      });
      await _reopen(store);
    } on TomSecretsAdminException catch (e) {
      if (e.details['reason'] == 'stale_base') {
        await _reopen(store);
      }
      rethrow;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      _ownSaves.remove(store);
      _reindex();
      notifyListeners();
    }
  }

  /// The entry [ref] in its open vault, or null.
  KdbxEntry? entryOf(TomSecretsEntryRef ref) => _vaultOf(ref.store)
      ?.file
      .body
      .rootGroup
      .getAllEntries()
      .where((e) => e.uuid == ref.uuid)
      .firstOrNull;

  /// Changes the entry [ref] with [change] and saves its vault.
  Future<void> updateEntry(
    TomSecretsEntryRef ref,
    void Function(KdbxEntry entry) change,
  ) async {
    final entry = entryOf(ref);
    if (entry == null) throw StateError('$ref is not open');
    change(entry);
    await save(ref.store);
  }

  /// A new entry of [type] titled [title] in [group] of [store] (its root
  /// when null), saved, and opened in the editor unless [select] is false
  /// (an entry of a vault open for editing only has no editor pane);
  /// answers it.
  Future<TomSecretsEntryRef> createEntry(
    String store, {
    KdbxUuid? group,
    required String title,
    TomSecretsEntryType type = TomSecretsEntryType.login,
    bool select = true,
  }) async {
    final file = _vaultOf(store)!.file;
    final parent = group == null
        ? file.body.rootGroup
        : _groupOf(file, group) ?? file.body.rootGroup;
    final entry = KdbxEntry.create(file, parent)..label = title;
    if (type != TomSecretsEntryType.login) {
      entry.setString(TomSecretsEntryFields.type, PlainValue(type.wireName));
    }
    parent.addEntry(entry);
    final ref = TomSecretsEntryRef(store, entry.uuid);
    await save(store);
    if (select) _selectedEntry = ref;
    notifyListeners();
    return ref;
  }

  /// The logins [proposal] would update: same user name, URL matching the
  /// page (5.7), in the vaults this device may write.
  List<TomSecretsProposalMatch> proposalMatches(TomSecretsProposal proposal) =>
      tomSecretsProposalMatches(proposal, [
        for (final s in resolution.stores)
          if (readOnlyReason(s.name) == null) ...s.entries,
      ]);

  /// The vaults a proposal may be saved into as a new login: the open,
  /// writable personal and shared vaults (a system vault holds no logins
  /// for the browser).
  List<String> get proposalVaults => [
    for (final v in _vaults.values)
      if (readOnlyReason(v.store) == null &&
          kindOf(v.store) != TomSecretsVaultKind.system)
        v.store,
  ];

  /// Saves [proposal] as a new login titled [title] in [store] and forgets
  /// it; answers the new entry (opened in the editor).
  Future<TomSecretsEntryRef> saveProposalAsNew(
    TomSecretsProposal proposal,
    String store, {
    String? title,
  }) async {
    final file = _vaultOf(store)?.file;
    if (file == null) throw StateError('$store is not open');
    final root = file.body.rootGroup;
    final entry = KdbxEntry.create(file, root);
    tomSecretsFillFromProposal(entry, proposal, title: title);
    root.addEntry(entry);
    final ref = TomSecretsEntryRef(store, entry.uuid);
    await save(store);
    connection.dropProposal(proposal.id);
    _selectedEntry = ref;
    notifyListeners();
    return ref;
  }

  /// Updates the login [ref] with [proposal]'s password (the old one stays
  /// in its history) and forgets the proposal.
  Future<void> applyProposal(
    TomSecretsProposal proposal,
    TomSecretsEntryRef ref,
  ) async {
    await updateEntry(ref, (e) => tomSecretsApplyProposal(e, proposal));
    connection.dropProposal(proposal.id);
  }

  /// Moves [refs] to the recycle bin of their vaults and saves them.
  Future<void> deleteEntries(Iterable<TomSecretsEntryRef> refs) =>
      _onEntries(refs, (file, entry) => file.deleteEntry(entry));

  /// Moves [refs] into [group] of [store] (entries of other vaults stay).
  Future<void> moveEntries(
    Iterable<TomSecretsEntryRef> refs,
    String store,
    KdbxUuid? group,
  ) => _onEntries(refs.where((r) => r.store == store), (file, entry) {
    final target = group == null
        ? file.body.rootGroup
        : _groupOf(file, group) ?? file.body.rootGroup;
    file.move(entry, target);
  });

  /// Adds [tag] to [refs].
  Future<void> tagEntries(Iterable<TomSecretsEntryRef> refs, String tag) =>
      _onEntries(refs, (file, entry) {
        final tags = tomSecretsTagsOf(entry);
        if (!tags.contains(tag)) entry.tags.set([...tags, tag].join(';'));
      });

  Future<void> _onEntries(
    Iterable<TomSecretsEntryRef> refs,
    void Function(KdbxFile file, KdbxEntry entry) change,
  ) async {
    final stores = <String>{};
    for (final ref in refs.toList()) {
      final entry = entryOf(ref);
      if (entry == null) continue;
      change(_vaultOf(ref.store)!.file, entry);
      stores.add(ref.store);
    }
    _marked.clear();
    for (final store in stores) {
      await save(store);
    }
  }

  /// A new group [name] under [parent] of [store] (its root when null).
  Future<void> createGroup(String store, KdbxUuid? parent, String name) async {
    final file = _vaultOf(store)!.file;
    file.createGroup(
      parent: parent == null
          ? file.body.rootGroup
          : _groupOf(file, parent) ?? file.body.rootGroup,
      name: name,
    );
    await save(store);
  }

  /// Renames [group] of [store].
  Future<void> renameGroup(String store, KdbxUuid group, String name) async {
    _groupOf(_vaultOf(store)!.file, group)?.name.set(name);
    await save(store);
  }

  /// Moves [group] of [store] under [parent] (the root when null).
  Future<void> moveGroup(String store, KdbxUuid group, KdbxUuid? parent) async {
    final file = _vaultOf(store)!.file;
    final moving = _groupOf(file, group);
    if (moving == null) return;
    file.moveGroup(
      moving,
      parent == null
          ? file.body.rootGroup
          : _groupOf(file, parent) ?? file.body.rootGroup,
    );
    await save(store);
  }

  /// The group [uuid] of [file], or null.
  static KdbxGroup? _groupOf(KdbxFile file, KdbxUuid uuid) => file
      .body
      .rootGroup
      .getAllGroups()
      .where((g) => g.uuid == uuid)
      .firstOrNull;

  /// The group [uuid] of [store], or null.
  KdbxGroup? groupOf(String store, KdbxUuid uuid) {
    final file = _vaults[store]?.file;
    return file == null ? null : _groupOf(file, uuid);
  }

  // Member keys (part-sharing, phase C), in the primary vault's
  // `tsm.sharing` group.

  KdbxFile? get _primaryFile => _vaults.values.firstOrNull?.file;

  /// Why the primary cannot take a member key or a member now (read-only,
  /// not open), or null.
  String? get sharingReadOnlyReason {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) return 'the primary vault is not open';
    return readOnlyReason(primary.store);
  }

  /// The `member-key` entry in use (the newest), or null before the user
  /// has one.
  TomSecretsEntryRef? get memberKeyEntry {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) return null;
    final entries = tomSecretsMemberKeyEntries(primary.file);
    // Why: during a rotation the current key is the one the record does not
    // name, whatever the creation times say (two keys made in one second).
    final rotating = TomSecretsRotations(primary.file)
        .list()
        .where((r) => r.kind == TomSecretsRotationKind.memberKey)
        .firstOrNull;
    final entry = rotating == null
        ? entries.firstOrNull
        : entries
                  .where(
                    (e) =>
                        tomSecretsMemberKeyRecipientOf(e)?.fingerprint !=
                        rotating.target,
                  )
                  .firstOrNull ??
              entries.firstOrNull;
    return entry == null ? null : TomSecretsEntryRef(primary.store, entry.uuid);
  }

  /// The user's member key's public key, read without its identity.
  TomSecretsAgeRecipient? get memberKeyRecipient {
    final ref = memberKeyEntry;
    final entry = ref == null ? null : entryOf(ref);
    return entry == null ? null : tomSecretsMemberKeyRecipientOf(entry);
  }

  /// When the member key was made.
  DateTime? get memberKeyCreated {
    final ref = memberKeyEntry;
    return ref == null ? null : entryOf(ref)?.times.creationTime.get();
  }

  /// The name the user gives with their member key (the entry's
  /// `UserName`), shown in the published key file.
  String get memberName {
    final ref = memberKeyEntry;
    final entry = ref == null ? null : entryOf(ref);
    return entry?.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
  }

  /// Makes the user's member key (a hybrid `age` key, DP-177) into the
  /// primary vault and saves it; the identity never leaves the vault.
  /// Refused when the user has one already.
  Future<TomSecretsAgeRecipient> createMemberKey({String name = ''}) async {
    final file = _primaryFile;
    if (file == null) throw StateError('no primary is open');
    final why = sharingReadOnlyReason;
    if (why != null) throw StateError(why);
    if (tomSecretsMemberKeyEntries(file).isNotEmpty) {
      throw StateError('a member key exists already');
    }
    final key = await TomSecretsMemberKey.generate();
    try {
      final entry = tomSecretsAddMemberKey(file, key);
      if (name.trim().isNotEmpty) {
        entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(name.trim()));
      }
      await save(_vaults.values.first.store);
      return key.recipient;
    } finally {
      key.dispose();
    }
  }

  /// Sets the name given with the member key, and saves.
  Future<void> setMemberName(String name) async {
    final ref = memberKeyEntry;
    if (ref == null) throw StateError('no member key');
    await updateEntry(
      ref,
      (e) => e.modify(
        () => e.setString(KdbxKeyCommon.USER_NAME, PlainValue(name.trim())),
      ),
    );
  }

  /// The directory of members (the public keys received), by name.
  List<TomSecretsMember> get members {
    final file = _primaryFile;
    return file == null ? const [] : tomSecretsMembers(file);
  }

  /// Adds a received public key to the directory as [name] ([checked]: the
  /// day the user compared its fingerprint with its owner) and saves the
  /// primary. Throws [TomSecretsMemberKeyException] for a key the directory
  /// holds, the user's own, or an invalid one.
  Future<void> addMember(
    String name,
    TomSecretsAgeRecipient recipient, {
    DateTime? checked,
  }) async {
    final file = _primaryFile;
    if (file == null) throw StateError('no primary is open');
    final why = sharingReadOnlyReason;
    if (why != null) throw StateError(why);
    await tomSecretsAddMember(
      file,
      name: name,
      recipient: recipient,
      checked: checked,
    );
    await save(_vaults.values.first.store);
  }

  /// Records that the user compared [member]'s fingerprint today, and saves.
  Future<void> markMemberChecked(TomSecretsMember member) => updateEntry(
    TomSecretsEntryRef(_vaults.values.first.store, member.entry.uuid),
    (e) => tomSecretsMarkMemberChecked(e, DateTime.now()),
  );

  /// Removes [member] from the directory (to the recycle bin), and saves.
  Future<void> removeMember(TomSecretsMember member) => deleteEntries([
    TomSecretsEntryRef(_vaults.values.first.store, member.entry.uuid),
  ]);

  // Shared vaults (part-sharing, phase C): the recipients file beside each
  // is read and written through the service, opened with the member key.

  /// The user as a member of a shared vault: their name and member key.
  TomSecretsSharedVaultMember _self(TomSecretsAgeRecipient own) => (
    name: memberName.trim().isEmpty ? 'Me' : memberName.trim(),
    recipient: own,
  );

  /// The open shared vaults (kind `shared`), the primary never among them.
  List<String> get sharedVaults => [
    for (final v in _vaults.values.skip(1))
      if (kindOf(v.store) == TomSecretsVaultKind.shared) v.store,
  ];

  /// The keys and members of a shared vault, from its recipients file
  /// opened with the member key: of the store [store], or of the vault at
  /// [location] not listed yet, read with [githubToken]. Throws
  /// [TomSecretsSharedVaultException] (`notAMember`) when the vault is not
  /// shared with the user's key, `TomSecretsAdminException` (`not_found`,
  /// reason `no_recipients`) when it has no recipients file.
  Future<TomSecretsSharedVaultRead> readSharedVault({
    String? store,
    String? location,
    String? githubToken,
  }) async {
    final answer = await connection.request('vault.recipients', {
      'store': ?store,
      'location': ?location,
      'githubToken': ?githubToken,
    });
    final bytes = base64.decode(answer['bytes']! as String);
    final primary = _primaryFile;
    final entries = primary == null
        ? const <KdbxEntry>[]
        : tomSecretsMemberKeyEntries(primary);
    if (entries.isEmpty) {
      throw StateError('make your member key first (open Sharing)');
    }
    // During a member key's rotation the file may be for the old or the
    // new key (part-key-rotation): each is tried, the newest first.
    TomSecretsSharedVaultException? notMember;
    for (final entry in entries) {
      final key = await tomSecretsMemberKeyOf(entry);
      try {
        final keys = await tomSecretsReadRecipientsFile(bytes, key);
        return TomSecretsSharedVaultRead(
          keys: keys,
          location: answer['location']! as String,
          revision: answer['revision']! as String,
        );
      } on TomSecretsSharedVaultException catch (e) {
        if (e.reason != TomSecretsSharedVaultFailure.notAMember) rethrow;
        notMember = e;
      } finally {
        key.dispose();
      }
    }
    throw notMember!;
  }

  /// Creates the shared vault [spec] names (its name, place, outer
  /// encryption; its kind is `shared`) for the user and [members] (hybrid
  /// keys only): a key file alone opens it, and its recipients file goes
  /// beside it. The vault is listed in the primary with its keys and
  /// served; the members need write access to its repository, which the
  /// user grants on GitHub.
  Future<String> createSharedVault(
    TomSecretsNewVaultSpec spec,
    List<TomSecretsMember> members, {
    DateTime? now,
  }) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final own = memberKeyRecipient;
    if (own == null) {
      throw StateError('make your member key first (open Sharing)');
    }
    final name = spec.name;
    if ({
      ..._vaults.keys,
      for (final v in TomSecretsPrimaryVaults(primary.file).list()) v.name,
    }.contains(name)) {
      throw ArgumentError.value(name, 'name', 'a vault $name exists already');
    }
    final location = tomSecretsNewVaultLocation(spec, primary.location);
    final keys = TomSecretsSharedVaultKeys.generate(
      name,
      members: [
        _self(own),
        for (final m in members) (name: m.name, recipient: m.recipient),
      ],
      outer: spec.outer,
    );
    final purpose = spec.purpose?.trim();
    final file = tomSecretsNewSharedVault(
      name,
      keys,
      purpose: purpose == null || purpose.isEmpty ? null : purpose,
    );
    final bytes = await tomSecretsEncodeStored(
      location,
      file,
      outerKey: keys.repositoryKey,
      cipher: spec.cipher,
    );
    final device = await _deviceSettings();
    final at = (now ?? DateTime.now()).toUtc();
    final token = spec.githubToken?.trim();
    try {
      await connection.request('vault.create', {
        'store': name,
        'location': location,
        'bytes': base64.encode(bytes),
        'keys': {
          'keyFile': base64.encode(keys.keyFile),
          'outerKey': ?keys.repositoryKey,
        },
        'recipients': base64.encode(await tomSecretsWriteRecipientsFile(keys)),
        if (token != null && token.isNotEmpty) 'githubToken': token,
        'keysDue': tomSecretsAddMonths(
          at,
          device.vaultKeyAgeMonths,
        ).toIso8601String(),
      });
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      keys.dispose();
    }
    await load();
    return location;
  }

  /// Adds [member] (a hybrid key) to the shared vault [store]: its
  /// recipients file written again for one member more, over the file as
  /// read (a member who changed it meanwhile makes it `stale_base`: read
  /// again). The vault and its keys stay.
  Future<void> addSharedVaultMember(
    String store,
    TomSecretsMember member,
  ) async {
    final read = await readSharedVault(store: store);
    final next = read.keys.withMember((
      name: member.name,
      recipient: member.recipient,
    ));
    try {
      await connection.request('vault.recipients.set', {
        'store': store,
        'bytes': base64.encode(await tomSecretsWriteRecipientsFile(next)),
        'baseRevision': read.revision,
      });
    } finally {
      read.keys.dispose();
      next.dispose();
    }
  }

  /// Removes the member [recipient] from the shared vault [store] (not the
  /// user's own key): new keys (a key file, and a repository key when outer
  /// encrypted) listed in the primary, then the vault re-keyed and its
  /// recipients file for the members left written with it in one commit.
  /// The removed member keeps what they saw, and older versions in the
  /// history stay readable to them. Answers the vault's entries, for the
  /// offer to rotate the important ones.
  Future<List<TomSecretsEntryRef>> removeSharedVaultMember(
    String store,
    TomSecretsAgeRecipient recipient, {
    DateTime? now,
  }) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    if (recipient == memberKeyRecipient) {
      throw ArgumentError('you cannot remove your own key');
    }
    final read = await readSharedVault(store: store);
    final next = read.keys.withoutMember(recipient);
    try {
      return await _rekeyShared(store, next, now: now);
    } finally {
      read.keys.dispose();
      next.dispose();
    }
  }

  /// Re-keys the shared vault [store] to [next] (a member removed, its key
  /// rotated): the new keys listed in the primary first, then the vault
  /// saved under them with its recipients file in one commit. [inVault]
  /// changes the vault's file first (a rotation record, whose lock refuses
  /// before anything is written). Answers the vault's entries.
  Future<List<TomSecretsEntryRef>> _rekeyShared(
    String store,
    TomSecretsSharedVaultKeys next, {
    DateTime? now,
    void Function(KdbxFile file)? inVault,
  }) async {
    final primary = _vaults.values.first;
    final list = TomSecretsPrimaryVaults(primary.file);
    final listed = list.byName(store);
    if (listed == null) throw StateError('the primary lists no $store');
    var opened = false;
    if (_vaultOf(store) == null) {
      await openUnserved(store);
      opened = true;
    }
    final vault = _vaultOf(store)!;
    inVault?.call(vault.file);
    final device = await _deviceSettings();
    final at = (now ?? DateTime.now()).toUtc();
    list.put(
      TomSecretsVaultKeys(
        name: listed.name,
        locator: listed.locator,
        keyFile: Uint8List.fromList(next.keyFile),
        outerKey: next.repositoryKey,
        githubToken: listed.githubToken,
        githubTokenExpires: listed.githubTokenExpires,
        expires: tomSecretsAddMonths(at, device.vaultKeyAgeMonths),
      ),
    );
    await save(primary.store);
    vault.file.credentials = next.credentials;
    if (next.repositoryKey != null) vault.outerKey = next.repositoryKey;
    await save(store, recipients: await tomSecretsWriteRecipientsFile(next));
    final reopened = _vaultOf(store)!;
    final refs = [
      for (final e in reopened.file.body.rootGroup.getAllEntries())
        if (e.label != tomSecretsMetadataTitle)
          TomSecretsEntryRef(store, e.uuid),
    ];
    if (opened) closeEditOnly(store);
    return refs;
  }

  // The guided rotation with a migration period (part-key-rotation, phase
  // C): the member key and the shared vaults' keys.

  /// The running rotation of the user's member key, or null.
  TomSecretsRotation? get memberKeyRotation {
    final file = _primaryFile;
    if (file == null) return null;
    return TomSecretsRotations(file)
        .list()
        .where((r) => r.kind == TomSecretsRotationKind.memberKey)
        .firstOrNull;
  }

  /// The running rotation of the shared vault [store]'s keys, or null.
  TomSecretsRotation? sharedVaultRotation(String store) {
    final file = _vaultOf(store)?.file;
    return file == null
        ? null
        : TomSecretsRotations(
            file,
          ).of(TomSecretsRotationKind.sharedVault, store);
  }

  /// Writes the recipients file of the shared vault [store] as [change]
  /// makes it from the file as read (null: nothing to change).
  Future<void> _changeRecipients(
    String store,
    TomSecretsSharedVaultKeys? Function(TomSecretsSharedVaultKeys keys) change,
  ) async {
    final read = await readSharedVault(store: store);
    try {
      final next = change(read.keys);
      if (next == null) return;
      try {
        await connection.request('vault.recipients.set', {
          'store': store,
          'bytes': base64.encode(await tomSecretsWriteRecipientsFile(next)),
          'baseRevision': read.revision,
        });
      } finally {
        if (!identical(next, read.keys)) next.dispose();
      }
    } finally {
      read.keys.dispose();
    }
  }

  /// Rotates the user's member key (part-key-rotation): a new key beside the
  /// old one in the primary, the rotation record started (its migration
  /// period, default 14 days), and every shared vault the user is a member
  /// of written for the old and the new key. The new public key is to be
  /// passed to the members (Sharing). The old key stays until the finish.
  /// Answers the new public key. Refused while a rotation runs; a vault
  /// that cannot be written now stays pending in the record.
  Future<TomSecretsAgeRecipient> startMemberKeyRotation({DateTime? now}) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final why = sharingReadOnlyReason;
    if (why != null) throw StateError(why);
    final old = memberKeyRecipient;
    if (old == null) throw StateError('you have no member key yet');
    final running = memberKeyRotation;
    if (running != null) {
      throw TomSecretsRotationException(
        'your member key is rotating already',
        rotation: running,
      );
    }
    final at = (now ?? DateTime.now()).toUtc();
    final name = memberName.trim();
    final pending = <String>[];
    for (final store in sharedVaults) {
      try {
        final read = await readSharedVault(store: store);
        if (read.keys.hasMember(old)) pending.add(store);
        read.keys.dispose();
      } on Object {
        // A vault it cannot read now is not on this key.
      }
    }
    final key = await TomSecretsMemberKey.generate();
    final TomSecretsAgeRecipient fresh = key.recipient;
    try {
      final entry = tomSecretsAddMemberKey(primary.file, key);
      if (name.isNotEmpty) {
        entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(name));
      }
    } finally {
      key.dispose();
    }
    final record = TomSecretsRotation(
      kind: TomSecretsRotationKind.memberKey,
      target: old.fingerprint,
      oldKeyId: old.fingerprint.substring(0, 16),
      newKeyId: fresh.fingerprint.substring(0, 16),
      started: at,
      switched: at,
      endsAt: at.add(tomSecretsRotationPeriod),
      by: name.isEmpty ? 'me' : name,
      pending: pending,
    );
    TomSecretsRotations(primary.file).start(record);
    await save(primary.store);
    final left = <String>[];
    for (final store in pending) {
      try {
        await _changeRecipients(
          store,
          (keys) => keys.hasMember(fresh)
              ? null
              : keys.withMember((name: _self(fresh).name, recipient: fresh)),
        );
      } on Object {
        left.add(store);
      }
    }
    TomSecretsRotations(
      _vaults.values.first.file,
    ).update(record.copyWith(pending: left));
    await save(_vaults.values.first.store);
    return fresh;
  }

  /// Finishes the member key's rotation: the old key dropped from every
  /// shared vault's recipients file (the new one added where it is
  /// missing), then the old key and the record removed from the primary.
  /// Before the migration period is over only with [early] ("finish now").
  /// Answers the vaults that could not be written; the rotation then stays,
  /// naming them, and the old key is kept.
  Future<List<String>> finishMemberKeyRotation({
    bool early = false,
    DateTime? now,
  }) async {
    final record = memberKeyRotation;
    if (record == null) {
      throw StateError('no rotation of your member key runs');
    }
    final at = (now ?? DateTime.now()).toUtc();
    if (!early && !record.isDueAt(at)) {
      throw StateError(
        'the migration period ends on '
        '${record.endsAt.toIso8601String().substring(0, 10)}',
      );
    }
    final fresh = memberKeyRecipient!;
    TomSecretsAgeRecipient? old;
    for (final e in tomSecretsMemberKeyEntries(_vaults.values.first.file)) {
      final r = tomSecretsMemberKeyRecipientOf(e);
      if (r?.fingerprint == record.target) old = r;
    }
    final failed = <String>[];
    if (old != null && old != fresh) {
      final gone = old;
      for (final store in sharedVaults) {
        try {
          await _changeRecipients(store, (keys) {
            if (!keys.hasMember(gone)) return null;
            final withNew = keys.hasMember(fresh)
                ? keys
                : keys.withMember((name: _self(fresh).name, recipient: fresh));
            final next = withNew.withoutRecipient(gone);
            if (!identical(withNew, keys)) withNew.dispose();
            return next;
          });
        } on Object {
          failed.add(store);
        }
      }
    }
    final file = _vaults.values.first.file;
    final records = TomSecretsRotations(file);
    if (failed.isNotEmpty) {
      records.update(record.copyWith(pending: failed));
      await save(_vaults.values.first.store);
      return failed;
    }
    final entries = tomSecretsMemberKeyEntries(file);
    final stale = entries
        .where(
          (e) =>
              tomSecretsMemberKeyRecipientOf(e)?.fingerprint == record.target,
        )
        .firstOrNull;
    if (stale != null && entries.length > 1) {
      // The old private key leaves the vault for good (no recycle bin).
      file.deletePermanently(stale);
    }
    records.end(TomSecretsRotationKind.memberKey, record.target);
    await save(_vaults.values.first.store);
    return const [];
  }

  /// Rotates the shared vault [store]'s keys without removing anyone
  /// (part-key-rotation): new keys for the same members, the rotation record
  /// written into the vault (its lock and migration period), the new keys
  /// listed in the primary and the vault re-keyed with its recipients file
  /// in one commit. The members take up the new key at their next load; a
  /// device that has not yet reads its copy under the old key, read-only.
  Future<void> rotateSharedVaultKeys(String store, {DateTime? now}) async {
    final read = await readSharedVault(store: store);
    final next = read.keys.rotated();
    final at = (now ?? DateTime.now()).toUtc();
    final own = memberKeyRecipient;
    try {
      await _rekeyShared(
        store,
        next,
        now: now,
        inVault: (file) => TomSecretsRotations(file).start(
          TomSecretsRotation(
            kind: TomSecretsRotationKind.sharedVault,
            target: store,
            oldKeyId: read.keys.keyId,
            newKeyId: next.keyId,
            started: at,
            switched: at,
            endsAt: at.add(tomSecretsRotationPeriod),
            by: memberName.trim().isEmpty ? 'me' : memberName.trim(),
            pending: [
              for (final m in read.keys.members)
                if (m.recipient != own) m.name,
            ],
          ),
        ),
      );
    } finally {
      read.keys.dispose();
      next.dispose();
    }
  }

  /// Finishes the rotation of the shared vault [store]'s keys: the record
  /// removed, and the history of its GitHub repository compacted, so no
  /// commit keeps the vault under the old key. Before the migration period
  /// is over only with [early]. Answers why the compaction failed, or null.
  Future<String?> finishSharedVaultRotation(
    String store, {
    bool early = false,
    DateTime? now,
  }) async {
    final record = sharedVaultRotation(store);
    if (record == null) throw StateError('no rotation of $store runs');
    final at = (now ?? DateTime.now()).toUtc();
    if (!early && !record.isDueAt(at)) {
      throw StateError(
        'the migration period ends on '
        '${record.endsAt.toIso8601String().substring(0, 10)}',
      );
    }
    TomSecretsRotations(
      _vaultOf(store)!.file,
    ).end(TomSecretsRotationKind.sharedVault, store);
    await save(store);
    final listed = TomSecretsPrimaryVaults(
      _vaults.values.first.file,
    ).byName(store);
    final slug = listed == null
        ? null
        : tomSecretsGitHubRepositoryOf(listed.locator);
    if (slug == null) return null;
    try {
      await connection.request('compact', {
        'repository': slug,
        'retentionDays': 0,
      });
      return null;
    } on TomSecretsAdminException catch (e) {
      return e.message;
    }
  }

  /// Joins the shared vault at [location] (`github:` or `file:`): its
  /// recipients file read with [githubToken] (that repository's token, kept
  /// in the vault's entry), opened with the member key, and the vault
  /// listed in the primary as [name] (default the name the file gives) with
  /// its keys, then served.
  Future<String> joinSharedVault({
    required String location,
    String? name,
    String? githubToken,
    DateTime? now,
  }) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final token = githubToken?.trim();
    final read = await readSharedVault(
      location: location.trim(),
      githubToken: token == null || token.isEmpty ? null : token,
    );
    try {
      final store = (name ?? '').trim().isEmpty
          ? read.keys.vault
          : name!.trim();
      if (!tomSecretsStoreNamePattern.hasMatch(store)) {
        throw ArgumentError.value(store, 'name', 'not a store name');
      }
      final list = TomSecretsPrimaryVaults(primary.file);
      if (store == primary.store ||
          _vaults.containsKey(store) ||
          list.byName(store) != null) {
        throw ArgumentError.value(
          store,
          'name',
          'a vault $store exists already',
        );
      }
      final device = await _deviceSettings();
      final at = (now ?? DateTime.now()).toUtc();
      list.put(
        TomSecretsVaultKeys(
          name: store,
          locator: read.location,
          keyFile: Uint8List.fromList(read.keys.keyFile),
          outerKey: read.keys.repositoryKey,
          githubToken: token == null || token.isEmpty ? null : token,
          expires: tomSecretsAddMonths(at, device.vaultKeyAgeMonths),
        ),
      );
      await save(primary.store);
      await connection.reload();
      await load();
      return store;
    } finally {
      read.keys.dispose();
    }
  }

  /// The shared vaults the primary lists whose keys no longer open them
  /// (another member removed someone and re-keyed): their recipients files
  /// read again, and the new keys listed in the primary, then served.
  /// Answers the vaults taken up; a vault not shared with the user's key
  /// any more, or without a recipients file, is left as it is.
  Future<List<String>> refreshSharedVaultKeys() async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null || memberKeyEntry == null) return const [];
    if (readOnlyReason(primary.store) != null) return const [];
    final list = TomSecretsPrimaryVaults(primary.file);
    final stuck = [
      for (final v in list.list())
        if (connection.stores[v.name]?.state == 'needs_unlock' ||
            _failures.any((f) => f.store == v.name))
          v,
    ];
    final updated = <String>[];
    for (final listed in stuck) {
      final TomSecretsSharedVaultRead read;
      try {
        read = await readSharedVault(store: listed.name);
      } on Object {
        continue;
      }
      try {
        final same =
            listed.keyFile != null &&
            listEquals(listed.keyFile, read.keys.keyFile) &&
            listed.outerKey == read.keys.repositoryKey;
        if (same) continue;
        list.put(
          TomSecretsVaultKeys(
            name: listed.name,
            locator: listed.locator,
            keyFile: Uint8List.fromList(read.keys.keyFile),
            outerKey: read.keys.repositoryKey,
            githubToken: listed.githubToken,
            githubTokenExpires: listed.githubTokenExpires,
            expires: listed.expires,
          ),
        );
        updated.add(listed.name);
      } finally {
        read.keys.dispose();
      }
    }
    if (updated.isEmpty) return updated;
    await save(primary.store);
    await connection.reload();
    await load();
    return updated;
  }

  // Single-entry exports and the inbox folders (part-sharing, phase C,
  // BP-34): a share written in the desktop app, read wherever the member key
  // is, carried as text, QR code, file or through a shared vault's inbox.

  /// Runs [use] with every member key of the primary opened as an `age`
  /// identity (the old one too during its rotation), disposed after.
  Future<T> _withMemberKeys<T>(
    Future<T> Function(List<TomSecretsAgeIdentity> identities) use,
  ) async {
    final file = _primaryFile;
    final keys = <TomSecretsMemberKey>[
      if (file != null)
        for (final e in tomSecretsMemberKeyEntries(file))
          await tomSecretsMemberKeyOf(e),
    ];
    try {
      return await use([for (final k in keys) TomSecretsAgeHybridIdentity(k)]);
    } finally {
      for (final k in keys) {
        k.dispose();
      }
    }
  }

  /// The share of [refs] as an `age` file: to [recipients] (members' hybrid
  /// keys, or classical keys alone) or under [passphrase]; it names the
  /// user (their member name and key's fingerprint) as its sender.
  Future<Uint8List> writeShare(
    List<TomSecretsEntryRef> refs, {
    List<TomSecretsAgeRecipient>? recipients,
    String? passphrase,
    int workFactor = tomSecretsAgeDefaultWorkFactor,
    DateTime? now,
  }) {
    final entries = [
      for (final r in refs)
        entryOf(r) ?? (throw StateError('no entry ${r.uuid} in ${r.store}')),
    ];
    final own = memberKeyRecipient;
    final name = memberName.trim();
    return tomSecretsWriteShare(
      tomSecretsShareOf(
        entries,
        from: own == null
            ? null
            : (
                name: name.isEmpty ? 'Unnamed' : name,
                fingerprint: own.fingerprint,
              ),
        now: now,
      ),
      recipients: recipients,
      passphrase: passphrase,
      workFactor: workFactor,
    );
  }

  /// The share in [bytes] (a `.tsmshare` file, a pasted or scanned armoured
  /// text), opened with the user's member keys or [passphrase]. Throws
  /// `TomSecretsAgeException` (`noMatch` when neither opens it) and
  /// `TomSecretsShareException`.
  Future<TomSecretsShare> readShare(List<int> bytes, {String? passphrase}) =>
      _withMemberKeys(
        (ids) => tomSecretsReadShare(bytes, [
          ...ids,
          if (passphrase != null) TomSecretsAgePassphraseIdentity(passphrase),
        ]),
      );

  /// Imports [share] into [group] of [store] (its root when null) as new
  /// entries and saves the vault. Answers them.
  Future<List<TomSecretsEntryRef>> importShare(
    TomSecretsShare share,
    String store,
    KdbxUuid? group,
  ) async {
    final file = _vaultOf(store)?.file;
    if (file == null) throw StateError('$store is not open');
    final why = readOnlyReason(store);
    if (why != null) throw StateError('$store is $why');
    final target = group == null
        ? file.body.rootGroup
        : _groupOf(file, group) ?? file.body.rootGroup;
    final added = tomSecretsImportShare(file, target, share);
    await _saveImported(store);
    return [for (final e in added) TomSecretsEntryRef(store, e.uuid)];
  }

  /// The shared vaults whose members include every one of [recipients]:
  /// where a share for them can go through the inbox.
  Future<List<String>> inboxVaultsFor(
    List<TomSecretsAgeRecipient> recipients,
  ) async {
    final out = <String>[];
    for (final store in sharedVaults) {
      if (readOnlyReason(store) != null) continue;
      try {
        final read = await readSharedVault(store: store);
        try {
          if (recipients.every(read.keys.hasMember)) out.add(store);
        } finally {
          read.keys.dispose();
        }
      } on Object {
        // A vault it cannot read now offers no inbox.
      }
    }
    return out;
  }

  /// Puts the share [bytes] into the inbox folder of each of [recipients]
  /// beside the shared vault [store]. Answers the package's name.
  Future<String> putIntoInbox(
    String store,
    List<TomSecretsAgeRecipient> recipients,
    Uint8List bytes,
  ) async {
    final answer = await connection.request('inbox.put', {
      'store': store,
      'members': [for (final r in recipients) r.fingerprint],
      'bytes': base64.encode(bytes),
    });
    return answer['name']! as String;
  }

  List<TomSecretsInboxPackage> _inbox = const [];

  /// The packages in the user's inbox folders, the newest first.
  List<TomSecretsInboxPackage> get inbox => _inbox;

  bool _checkingInbox = false;

  /// Reads the inbox folders beside every shared vault (at each load, the
  /// sync): the packages in the user's own folders (each member key's
  /// fingerprint) opened with the member key, and every package of any
  /// folder more than 30 days old deleted. A vault it cannot reach now,
  /// or a service that has no inbox (a phone), is left for the next load.
  Future<void> checkInbox({DateTime? now}) async {
    final file = _primaryFile;
    if (_checkingInbox || file == null) return;
    _checkingInbox = true;
    try {
      final at = (now ?? DateTime.now()).toUtc();
      final own = {
        for (final e in tomSecretsMemberKeyEntries(file))
          ?tomSecretsMemberKeyRecipientOf(e)?.fingerprint,
      };
      final known = {
        for (final p in _inbox) '${p.store}/${p.member}/${p.name}',
      };
      final found = <TomSecretsInboxPackage>[];
      for (final store in sharedVaults) {
        final List<Map<Object?, Object?>> files;
        try {
          final answer = await connection.request('inbox.list', {
            'store': store,
          });
          files = (answer['files'] as List? ?? const []).cast();
        } on Object {
          continue;
        }
        final expired = [
          for (final f in files)
            if (tomSecretsInboxExpired(f['name']! as String, at))
              {'member': f['member'], 'name': f['name']},
        ];
        if (expired.isNotEmpty && readOnlyReason(store) == null) {
          try {
            await connection.request('inbox.delete', {
              'store': store,
              'files': expired,
            });
          } on Object {
            // Deleted by the next member's sync.
          }
        }
        for (final f in files) {
          final member = f['member']! as String;
          final name = f['name']! as String;
          if (!own.contains(member) ||
              !tomSecretsIsInboxName(name) ||
              tomSecretsInboxExpired(name, at)) {
            continue;
          }
          final key = '$store/$member/$name';
          if (known.contains(key)) {
            found.add(
              _inbox.firstWhere(
                (p) => '${p.store}/${p.member}/${p.name}' == key,
              ),
            );
            continue;
          }
          found.add(await _readInboxPackage(store, member, name));
        }
      }
      found.sort((a, b) => b.name.compareTo(a.name));
      _inbox = found;
      notifyListeners();
    } finally {
      _checkingInbox = false;
    }
  }

  Future<TomSecretsInboxPackage> _readInboxPackage(
    String store,
    String member,
    String name,
  ) async {
    final Uint8List bytes;
    try {
      final read = await connection.request('inbox.read', {
        'store': store,
        'member': member,
        'name': name,
      });
      bytes = base64.decode(read['bytes']! as String);
    } on Object catch (e) {
      return TomSecretsInboxPackage(
        store: store,
        member: member,
        name: name,
        bytes: Uint8List(0),
        problem: 'it cannot be read now (${_describe(e)})',
      );
    }
    if (tomSecretsAgeIsPassphrase(bytes)) {
      return TomSecretsInboxPackage(
        store: store,
        member: member,
        name: name,
        bytes: bytes,
        passphrase: true,
      );
    }
    try {
      return TomSecretsInboxPackage(
        store: store,
        member: member,
        name: name,
        bytes: bytes,
        share: await readShare(bytes),
      );
    } on TomSecretsAgeException catch (e) {
      return TomSecretsInboxPackage(
        store: store,
        member: member,
        name: name,
        bytes: bytes,
        problem: e.message,
      );
    } on TomSecretsShareException catch (e) {
      return TomSecretsInboxPackage(
        store: store,
        member: member,
        name: name,
        bytes: bytes,
        problem: e.message,
      );
    }
  }

  /// Imports the inbox [package] into [group] of [store] ([passphrase] for
  /// one written under a passphrase), then deletes it from the folder.
  /// Answers the entries imported.
  Future<List<TomSecretsEntryRef>> acceptInboxPackage(
    TomSecretsInboxPackage package,
    String store,
    KdbxUuid? group, {
    String? passphrase,
  }) async {
    final share =
        package.share ?? await readShare(package.bytes, passphrase: passphrase);
    final refs = await importShare(share, store, group);
    await declineInboxPackage(package);
    return refs;
  }

  /// Deletes the inbox [package] from its folder without importing it.
  Future<void> declineInboxPackage(TomSecretsInboxPackage package) async {
    await connection.request('inbox.delete', {
      'store': package.store,
      'files': [
        {'member': package.member, 'name': package.name},
      ],
    });
    _inbox = [
      for (final p in _inbox)
        if (!identical(p, package)) p,
    ];
    notifyListeners();
  }

  // The guided rotation of the own vaults with a migration period
  // (part-key-rotation, phase C): prepare (the next keys beside the old ones
  // in the primary, which every device takes), switch (the vaults re-keyed;
  // a repository key rotated alone keeps the old key's slot), finish (the
  // old key gone, the history cut), or cancel before the switch.

  /// The guided rotation running for [store]'s keys, or null: of its key
  /// file (`vaultKeys`, target the store) or of its repository key alone
  /// (`repositoryKey`, target its repository).
  TomSecretsRotation? guidedRotationOf(String store) {
    final file = _primaryFile;
    if (file == null) return null;
    final location = _locationOf(store);
    if (location == null) return null;
    final rotations = TomSecretsRotations(file);
    return rotations.of(TomSecretsRotationKind.vaultKeys, store) ??
        rotations.of(
          TomSecretsRotationKind.repositoryKey,
          tomSecretsRepositoryOf(location),
        );
  }

  /// The devices that do not hold the new key of [rotation] yet (their
  /// device record lacks its id): the ones it still waits for.
  List<TomSecretsDeviceRecord> guidedRotationMissing(
    TomSecretsRotation rotation,
  ) {
    final file = _primaryFile;
    return file == null
        ? const []
        : TomSecretsDeviceRecords(file).missingKey(rotation.newKeyId);
  }

  String? _locationOf(String store) {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) return null;
    if (store == primary.store) return primary.location;
    return TomSecretsPrimaryVaults(primary.file).byName(store)?.locator;
  }

  /// This device's name (`pair.identity`), who a rotation names as started
  /// by.
  Future<String> _deviceName() async {
    try {
      final answer = await connection.request('pair.identity');
      final device = answer['device'];
      if (device is String && device.isNotEmpty) return device;
    } on Object {
      // Named by the user's member name below.
    }
    return memberName.trim().isEmpty ? 'this device' : memberName.trim();
  }

  /// The vaults a guided rotation of [store] changes: [store] itself, and
  /// for a new repository key every vault of the same repository under the
  /// same key (the primary among them when it is one), as the rotation by
  /// hand does. Answers further vault names and whether the primary is one.
  ({List<String> further, bool primary}) _guidedTargets(
    String store, {
    required bool repositoryKey,
  }) {
    final primary = _vaults.values.first;
    final list = TomSecretsPrimaryVaults(primary.file);
    final isPrimary = store == primary.store;
    final location = _locationOf(store)!;
    final outer = isPrimary ? primary.outerKey : list.byName(store)!.outerKey;
    final repository = tomSecretsRepositoryOf(location);
    final further = <String>[
      if (!isPrimary) store,
      if (repositoryKey)
        for (final v in list.list())
          if (v.name != store &&
              v.outerKey == outer &&
              tomSecretsRepositoryOf(v.locator) == repository)
            v.name,
    ];
    final primaryToo =
        isPrimary ||
        (repositoryKey &&
            primary.outerKey == outer &&
            tomSecretsRepositoryOf(primary.location) == repository);
    return (further: further, primary: primaryToo);
  }

  /// Prepares a guided rotation of [store]'s keys (step 1): a new key file
  /// ([newKeyFile]) and/or, for a `.tsmx` vault, a new repository key
  /// ([newRepositoryKey]) written beside the old ones into the primary
  /// (each affected vault's entry, the primary's own `next-keys` entry),
  /// nothing re-encrypted, and the rotation record started with its 14-day
  /// migration period and the paired devices as pending. Every device's
  /// service takes the next keys at its next sync. Refused while a guided
  /// rotation of the same target runs, and for a shared vault (its keys
  /// rotate on the Sharing screen).
  Future<TomSecretsRotation> prepareGuidedRotation(
    String store, {
    bool newKeyFile = false,
    bool newRepositoryKey = false,
    DateTime? now,
  }) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    if (!newKeyFile && !newRepositoryKey) {
      throw ArgumentError('a new key file or a new repository key');
    }
    if (kindOf(store) == TomSecretsVaultKind.shared) {
      throw StateError('a shared vault\'s key rotates on the Sharing screen');
    }
    final why = readOnlyReason(primary.store);
    if (why != null) throw StateError(why);
    final location = _locationOf(store);
    if (location == null) throw StateError('the primary lists no $store');
    final outer = location.endsWith(tomSecretsOuterSuffix);
    if (newRepositoryKey && !outer) {
      throw ArgumentError('$store is not outer encrypted');
    }
    final isPrimary = store == primary.store;
    final held = await _heldKeys([store]);
    final old = held[store]!;
    if (isPrimary && newKeyFile && old['compositeKey'] is String) {
      throw StateError(
        'Changing the key file needs the master password, which this unlock '
        '(the OS unlock) does not hold: lock, unlock with the master '
        'password, and prepare again.',
      );
    }
    final at = (now ?? DateTime.now()).toUtc();
    final keyFile = newKeyFile ? TomSecretsKeyFile.generate().toBytes() : null;
    final outerKey = newRepositoryKey
        ? TomSecretsRepositoryKey.generate().toBase64()
        : null;
    final kind = newKeyFile
        ? TomSecretsRotationKind.vaultKeys
        : TomSecretsRotationKind.repositoryKey;
    String id({List<int>? keyFile, String? outerKey}) =>
        tomSecretsVaultKeyIds(
          keyFile: keyFile,
          outerKey: outerKey,
        ).firstOrNull ??
        'none';
    final oldKeyFile = old['keyFile'] is String
        ? base64.decode(old['keyFile']! as String)
        : null;
    final record = TomSecretsRotation(
      kind: kind,
      target: newKeyFile ? store : tomSecretsRepositoryOf(location),
      oldKeyId: newKeyFile
          ? id(keyFile: oldKeyFile)
          : id(outerKey: old['outerKey'] as String?),
      newKeyId: newKeyFile ? id(keyFile: keyFile) : id(outerKey: outerKey),
      started: at,
      endsAt: at.add(tomSecretsRotationPeriod),
      by: await _deviceName(),
      pending: [
        for (final r in TomSecretsDeviceRecords(primary.file).list())
          if (!r.isRevoked) r.device,
      ],
    );
    // The record first: its lock refuses before anything is written.
    TomSecretsRotations(primary.file).start(record);
    final targets = _guidedTargets(store, repositoryKey: newRepositoryKey);
    final list = TomSecretsPrimaryVaults(primary.file);
    for (final name in targets.further) {
      list.put(
        list
            .byName(name)!
            .copyWith(
              nextKeyFile: name == store ? keyFile : null,
              nextOuterKey: outerKey,
            ),
      );
    }
    if (targets.primary) {
      TomSecretsPrimaryNextKeys(
        keyFile: isPrimary ? keyFile : null,
        outerKey: outerKey,
      ).writeTo(primary.file);
    }
    await save(primary.store);
    return record;
  }

  /// Switches the guided rotation of [store] (step 2): the next keys become
  /// the keys, written into the primary first (a repository key rotated
  /// alone keeps the old one as the key whose slot the file keeps), then
  /// every affected vault re-keyed: the primary with its new keys, a
  /// repository key rotated alone with two slots. A device holding only the
  /// old key keeps reading a two-slot file but writes nothing; after a key
  /// file change it reads its copy under the old key until it has the new
  /// one. The record names the switch. Works on the primary as it is now
  /// (it is read again first: other devices wrote their device records).
  Future<void> switchGuidedRotation(String store, {DateTime? now}) async {
    await connection.reload();
    await load();
    final primary = _vaults.values.first;
    final record = guidedRotationOf(store);
    if (record == null) throw StateError('no guided rotation of $store runs');
    if (record.switched != null) {
      throw StateError('the rotation of ${record.target} switched already');
    }
    final at = (now ?? DateTime.now()).toUtc();
    final repositoryOnly = record.kind == TomSecretsRotationKind.repositoryKey;
    final list = TomSecretsPrimaryVaults(primary.file);
    final further = [
      for (final v in list.list())
        if (v.hasNext) v.name,
    ];
    final next = TomSecretsPrimaryNextKeys.of(primary.file);
    final device = await _deviceSettings();
    final opened = <String>[];
    for (final name in further) {
      if (_vaultOf(name) == null) {
        await openUnserved(name);
        opened.add(name);
      }
    }
    for (final name in further) {
      final v = list.byName(name)!;
      list.put(
        v.copyWith(
          keyFile: v.nextKeyFile,
          outerKey: v.nextOuterKey,
          previousOuterKey: repositoryOnly ? v.outerKey : null,
          clearPrevious: !repositoryOnly,
          clearNext: true,
          expires: tomSecretsAddMonths(at, device.vaultKeyAgeMonths),
        ),
      );
    }
    Map<String, Object?>? primaryKeys;
    if (next != null) {
      final held = (await _heldKeys([primary.store]))[primary.store]!;
      final oldOuter = primary.outerKey;
      if (repositoryOnly) {
        TomSecretsPrimaryNextKeys(
          outerKey: next.outerKey,
          previousOuterKey: oldOuter,
        ).writeTo(primary.file);
      }
      final keyFile = next.keyFile != null
          ? base64.encode(next.keyFile!)
          : held['keyFile'] as String?;
      if (next.keyFile != null) {
        primary.file.credentials = tomSecretsVaultCredentials(
          password: held['password'] as String?,
          keyFile: next.keyFile,
        );
      }
      if (next.outerKey != null) {
        primary.outerKey = next.outerKey;
        primary.previousOuterKey = repositoryOnly ? oldOuter : null;
      }
      primaryKeys = {
        ...(next.keyFile == null
            ? _heldKeysWire(held)
            : {'password': held['password'] as String? ?? ''}),
        'keyFile': ?keyFile,
        'outerKey': ?primary.outerKey,
        'previousOuterKey': ?primary.previousOuterKey,
      };
    }
    final rotations = TomSecretsRotations(primary.file);
    rotations.update(record.copyWith(switched: at));
    await save(primary.store, keys: primaryKeys);
    for (final name in further) {
      final vault = _vaultOf(name)!;
      final keys = list.byName(name)!;
      vault.file.credentials = tomSecretsVaultCredentials(
        password: keys.password,
        keyFile: keys.keyFile == null
            ? null
            : Uint8List.fromList(keys.keyFile!),
      );
      vault.outerKey = keys.outerKey;
      vault.previousOuterKey = keys.previousOuterKey;
      await save(name);
    }
    for (final name in opened) {
      closeEditOnly(name);
    }
  }

  /// Finishes the guided rotation of [store] (step 3), after the migration
  /// period or, with [early], at once: the old repository key leaves the
  /// primary (the vaults' entries, the primary's `next-keys` entry), every
  /// two-slot file is written again with the new key's slot only, the
  /// record ends, and the history of every `github:` repository written is
  /// cut (retention 0). Answers the devices that never took the new key and
  /// the repositories whose history could not be cut, with why.
  Future<
    ({List<TomSecretsDeviceRecord> missing, Map<String, String> notCompacted})
  >
  finishGuidedRotation(
    String store, {
    bool early = false,
    DateTime? now,
  }) async {
    await connection.reload();
    await load();
    final primary = _vaults.values.first;
    final record = guidedRotationOf(store);
    if (record == null) throw StateError('no guided rotation of $store runs');
    if (record.switched == null) {
      throw StateError('the rotation did not switch yet: switch or cancel it');
    }
    final at = (now ?? DateTime.now()).toUtc();
    if (!early && !record.isDueAt(at)) {
      throw StateError(
        'the migration period ends on '
        '${record.endsAt.toIso8601String().substring(0, 10)}',
      );
    }
    final missing = guidedRotationMissing(record);
    final list = TomSecretsPrimaryVaults(primary.file);
    final rewritten = [
      for (final v in list.list())
        if (v.previousOuterKey != null) v.name,
    ];
    final targets = record.kind == TomSecretsRotationKind.vaultKeys
        ? [record.target]
        : rewritten;
    final opened = <String>[];
    for (final name in rewritten) {
      if (_vaultOf(name) == null) {
        await openUnserved(name);
        opened.add(name);
      }
      list.put(list.byName(name)!.copyWith(clearPrevious: true));
    }
    final primaryRewritten = TomSecretsPrimaryNextKeys.clear(primary.file);
    primary.previousOuterKey = null;
    TomSecretsRotations(primary.file).end(record.kind, record.target);
    await save(primary.store);
    for (final name in rewritten) {
      _vaultOf(name)!.previousOuterKey = null;
      await save(name);
    }
    for (final name in opened) {
      closeEditOnly(name);
    }
    final repositories = {
      for (final name in {
        ...targets,
        ...rewritten,
        if (primaryRewritten) primary.store,
      })
        ?tomSecretsGitHubRepositoryOf(_locationOf(name) ?? ''),
    };
    final notCompacted = <String, String>{};
    for (final slug in repositories) {
      try {
        await connection.request('compact', {
          'repository': slug,
          'retentionDays': 0,
        });
      } on TomSecretsAdminException catch (e) {
        notCompacted[slug] = e.message;
      }
    }
    return (missing: missing, notCompacted: notCompacted);
  }

  /// Cancels the guided rotation of [store] before its switch: the next
  /// keys leave the primary (and with it every device's keychain at its
  /// next sync) and the record ends. After the switch a rotation only goes
  /// forward.
  Future<void> cancelGuidedRotation(String store) async {
    final primary = _vaults.values.firstOrNull;
    if (primary == null) throw StateError('no primary is open');
    final record = guidedRotationOf(store);
    if (record == null) throw StateError('no guided rotation of $store runs');
    if (record.switched != null) {
      throw StateError(
        'the rotation switched already: it only goes forward (finish now)',
      );
    }
    final list = TomSecretsPrimaryVaults(primary.file);
    for (final v in list.list()) {
      if (v.hasNext) list.put(v.copyWith(clearNext: true));
    }
    TomSecretsPrimaryNextKeys.clear(primary.file);
    TomSecretsRotations(primary.file).end(record.kind, record.target);
    await save(primary.store);
  }

  /// Marks [refs] for rotation after a member was removed: each gets the
  /// tag `rotate` and expires today, so the Health screen lists it until
  /// its secret is changed (at its service too).
  Future<void> markForRotation(Iterable<TomSecretsEntryRef> refs) {
    final today = DateTime.now().toUtc();
    return _onEntries(refs, (file, entry) {
      entry.modify(() {
        final tags = tomSecretsTagsOf(entry);
        if (!tags.contains(tomSecretsRotateTag)) {
          entry.tags.set([...tags, tomSecretsRotateTag].join(';'));
        }
        entry.times.expires.set(true);
        entry.times.expiryTime.set(today);
      });
    });
  }

  void _reindex() {
    _indexRevision++;
    _resolution = null;
    final views = <TomSecretsEntryView>[];
    for (final vault in _vaults.values) {
      final root = vault.file.body.rootGroup;
      final bin = vault.file.recycleBin;
      final overlays = <String, int>{};
      final plain = <(KdbxEntry, List<String>, bool)>[];
      void walk(KdbxGroup group, List<String> path, bool inBin) {
        for (final entry in group.entries) {
          if (path.any(tomSecretsIsOverlayGroup)) {
            final base = [
              ...path.where((p) => !tomSecretsIsOverlayGroup(p)),
              entry.label ?? '',
            ].join('/');
            overlays[base] = (overlays[base] ?? 0) + 1;
          } else {
            plain.add((entry, path, inBin));
          }
        }
        for (final child in group.groups) {
          walk(child, [
            ...path,
            child.name.get() ?? '',
          ], inBin || (bin != null && child.uuid == bin.uuid));
        }
      }

      walk(root, const [], false);
      for (final (entry, path, inBin) in plain) {
        views.add(
          TomSecretsEntryView._(
            ref: TomSecretsEntryRef(vault.store, entry.uuid),
            entry: entry,
            groups: path,
            overlays: overlays[[...path, entry.label ?? ''].join('/')] ?? 0,
            inRecycleBin: inBin,
          ),
        );
      }
    }
    _index = views;
  }

  /// Drops every vault, the index, the selection and the marks: on `locked`
  /// and when the connection drops.
  void clear() {
    _vaults.clear();
    _failures.clear();
    _editOnly.clear();
    _unserved = const [];
    _resolution = null;
    _index = const [];
    _indexRevision++;
    _selectedEntry = null;
    _selectedGroup = null;
    _selectedStore = null;
    _marked.clear();
    _changedElsewhere = null;
    _query = '';
    notifyListeners();
  }

  void _onConnection() {
    final c = connection;
    if (c.locked || c.phase != TomSecretsConnectionPhase.attached) {
      if (_vaults.isNotEmpty || _index.isNotEmpty) clear();
    } else if (_vaults.isEmpty && !_loading && _failures.isEmpty) {
      unawaited(load().catchError((Object _) {}));
    }
  }

  void _onEvent(Map<String, Object?> event) {
    if (event['op'] != 'store_changed') return;
    final store = event['store'];
    if (store is! String || _ownSaves.contains(store)) return;
    final vault = _vaultOf(store);
    if (vault == null || event['revision'] == vault.revision) return;
    unawaited(_changed(store));
  }

  Future<void> _changed(String store) async {
    try {
      await _reopen(store);
    } on Object catch (e) {
      _failures.add(TomSecretsVaultFailure(store, _describe(e)));
    }
    if (_selectedEntry?.store == store) _changedElsewhere = _selectedEntry;
    _reindex();
    notifyListeners();
  }

  static String _describe(Object e) => switch (e) {
    TomSecretsAdminException(:final kind, :final message, :final details) =>
      details['reason'] == 'too_large'
          ? 'the file is too large to edit before phase B ($message)'
          : '$kind: $message',
    KdbxInvalidKeyException() => 'the keys the service holds do not open it',
    _ => '$e',
  };

  /// Test support: the bytes [store] would save now.
  @visibleForTesting
  Future<Uint8List> encodedForTest(String store) {
    final vault = _vaults[store]!;
    return tomSecretsEncodeStored(
      vault.location,
      vault.file,
      outerKey: vault.outerKey,
      cipher: vault.cipher ?? TomSecretsOuterCipher.xchacha20Poly1305,
    );
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    connection.removeListener(_onConnection);
    clear();
    super.dispose();
  }
}

/// **[C]** A shared vault's recipients file as read
/// ([TomSecretsSession.readSharedVault]).
final class TomSecretsSharedVaultRead {
  /// What the file holds, read from [location] at [revision].
  const TomSecretsSharedVaultRead({
    required this.keys,
    required this.location,
    required this.revision,
  });

  /// The vault's keys and members; the reader disposes them.
  final TomSecretsSharedVaultKeys keys;

  /// The vault's locator.
  final String location;

  /// The file's revision, which a write names as its base.
  final String revision;
}

/// The tag of an entry to rotate after a member left a shared vault.
const String tomSecretsRotateTag = 'rotate';
