// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The phone's own files (part-mobile, `file:` vaults [B]): a KDBX file the
/// user picks — through the iOS document picker (kept by a security-scoped
/// bookmark) or Android's Storage Access Framework (a persisted URI
/// permission), e.g. in iCloud Drive — read into memory, written back on
/// save, merged when it changed there; the app keeps no copy. Also the
/// attachments: a file picked to attach, and an attachment handed to the
/// share sheet.
///
/// A phone's document vault is listed in the primary like every vault, under
/// a locator naming the device, `file:/tsm-document/<device>/<file name>`;
/// the phone maps it to its document. Another device has no such document
/// and cannot reach it, as with a desktop's `file:` vault.
library;

import 'package:flutter/services.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsFiles, TomSecretsPreferences;

/// A document the user picked.
final class TomSecretsPickedDocument {
  /// The document [id] (the platform's bookmark or URI) named [name].
  const TomSecretsPickedDocument({required this.id, required this.name});

  /// The platform's handle of it.
  final String id;

  /// Its file name.
  final String name;
}

/// The platform's documents.
abstract interface class TomSecretsDocuments {
  /// A KDBX file to keep a vault in, picked by the user, kept accessible
  /// from then on; null when cancelled.
  Future<TomSecretsPickedDocument?> pickVault();

  /// The document [id] as it is now. Throws [TomSecretsDocumentException]
  /// when it is gone or no longer allowed.
  Future<Uint8List> read(String id);

  /// Replaces the document [id] with [bytes].
  Future<void> write(String id, Uint8List bytes);

  /// A file picked to read once (an attachment): its name and bytes, or
  /// null when cancelled.
  Future<({String name, Uint8List bytes})?> pickFile();

  /// Hands [bytes] named [name] to the share sheet (to open or save it in
  /// another app); answers whether the sheet was shown.
  Future<bool> share(String name, Uint8List bytes);
}

/// No documents (a host without them, the tests of GitHub vaults only).
final class TomSecretsNoDocuments implements TomSecretsDocuments {
  /// The none.
  const TomSecretsNoDocuments();

  static Never _none() =>
      throw const TomSecretsDocumentException('this device has no files');

  @override
  Future<TomSecretsPickedDocument?> pickVault() async => null;

  @override
  Future<Uint8List> read(String id) async => _none();

  @override
  Future<void> write(String id, Uint8List bytes) async => _none();

  @override
  Future<({String name, Uint8List bytes})?> pickFile() async => null;

  @override
  Future<bool> share(String name, Uint8List bytes) async => false;
}

/// A document that cannot be read or written.
final class TomSecretsDocumentException implements Exception {
  /// The failure described by [message].
  const TomSecretsDocumentException(this.message);

  /// What failed.
  final String message;

  @override
  String toString() => 'TomSecretsDocumentException: $message';
}

/// [TomSecretsDocuments] over the app's documents channel (iOS
/// UIDocumentPicker with security-scoped bookmarks and NSFileCoordinator,
/// Android ACTION_OPEN_DOCUMENT with persisted permissions).
final class TomSecretsChannelDocuments implements TomSecretsDocuments {
  /// The documents over [channel].
  const TomSecretsChannelDocuments({
    this.channel = const MethodChannel('tom_secrets_mobile/documents'),
  });

  /// The channel (`pickVault`, `read`, `write`, `pickFile`, `share`).
  final MethodChannel channel;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw TomSecretsDocumentException(e.message ?? e.code);
    }
  }

  @override
  Future<TomSecretsPickedDocument?> pickVault() async {
    final picked = await _call<Map<Object?, Object?>>('pickVault');
    if (picked == null) return null;
    return TomSecretsPickedDocument(
      id: picked['id']! as String,
      name: picked['name']! as String,
    );
  }

  @override
  Future<Uint8List> read(String id) async =>
      (await _call<Uint8List>('read', {'id': id}))!;

  @override
  Future<void> write(String id, Uint8List bytes) =>
      _call<void>('write', {'id': id, 'bytes': bytes});

  @override
  Future<({String name, Uint8List bytes})?> pickFile() async {
    final picked = await _call<Map<Object?, Object?>>('pickFile');
    if (picked == null) return null;
    return (
      name: picked['name']! as String,
      bytes: picked['bytes']! as Uint8List,
    );
  }

  @override
  Future<bool> share(String name, Uint8List bytes) async =>
      await _call<bool>('share', {'name': name, 'bytes': bytes}) ?? false;
}

/// The attachments' files on a phone: picked from the documents, shared
/// through the share sheet (`TomSecretsHost.attachmentsShare`).
final class TomSecretsMobileFiles implements TomSecretsFiles {
  /// The files over [documents].
  const TomSecretsMobileFiles(this.documents);

  /// The documents.
  final TomSecretsDocuments documents;

  @override
  Future<({String name, Uint8List bytes})?> pick() => documents.pickFile();

  @override
  Future<bool> save(String name, Uint8List bytes) =>
      documents.share(name, bytes);

  /// A phone has no paths to choose (the import and the First run, which
  /// ask for one, are desktop screens); [read] and [delete] therefore have
  /// none to work on.
  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => null;

  @override
  Future<Uint8List> read(String path) =>
      throw UnsupportedError('a phone has no file paths');

  @override
  Future<bool> delete(String path) async => false;
}

/// Which document each of this phone's `file:` vaults is (device
/// preferences, never synced).
final class TomSecretsDocumentRegistry {
  /// The registry in [preferences].
  TomSecretsDocumentRegistry(this.preferences);

  /// The device preferences.
  final TomSecretsPreferences preferences;

  static String _key(String locator) => 'mobile.document.$locator';

  /// The folder of a phone's document vaults: `/tsm-document/<device>/`.
  static String folderOf(String device) => '/tsm-document/$device/';

  /// The document of [locator], or null (not this phone's).
  String? idOf(String locator) => preferences.read(_key(locator));

  /// Records [locator] as the document [id].
  Future<void> put(String locator, String id) =>
      preferences.write(_key(locator), id);

  /// Forgets [locator].
  Future<void> forget(String locator) => preferences.write(_key(locator), null);

  /// A new locator for a document named [name] on [device], not taken yet.
  String locatorFor(String device, String name) {
    final safe = name.replaceAll(RegExp(r'[/\\:]'), '_');
    final dot = safe.lastIndexOf('.');
    final (stem, ext) = dot > 0
        ? (safe.substring(0, dot), safe.substring(dot))
        : (safe, '');
    var locator = 'file:${folderOf(device)}$safe';
    for (var n = 2; idOf(locator) != null; n++) {
      locator = 'file:${folderOf(device)}$stem-$n$ext';
    }
    return locator;
  }
}

/// `file:` vaults on a phone: this phone's documents, read and written
/// whole; a vault of another device's file (another phone's document, a
/// desktop's path) cannot be reached here.
final class TomSecretsDocumentOpener implements TomSecretsVaultOpener {
  /// The opener over [documents], mapping locators through [registry].
  TomSecretsDocumentOpener({
    required this.documents,
    required this.registry,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The documents.
  final TomSecretsDocuments documents;

  /// Which document each locator is.
  final TomSecretsDocumentRegistry registry;

  final DateTime Function() _clock;

  String _id(String locator) {
    final id = registry.idOf(locator);
    if (id == null) {
      throw TomSecretsDocumentException('$locator is a file on another device');
    }
    return id;
  }

  @override
  Future<TomSecretsOpenedVault> open(
    String locator,
    Credentials credentials, {
    String? outerKey,
  }) async {
    final stored = await read(locator);
    return TomSecretsOpenedVault(
      locator: locator,
      file: await decode(locator, stored, credentials, outerKey: outerKey),
      stored: stored,
      fetchedAt: _clock().toUtc(),
    );
  }

  @override
  Future<Uint8List> read(String locator) => documents.read(_id(locator));

  @override
  Future<String> revision(String locator) async =>
      tomSecretsBlobId(await read(locator));

  @override
  Future<KdbxFile> decode(
    String locator,
    Uint8List stored,
    Credentials credentials, {
    String? outerKey,
  }) =>
      tomSecretsDecodeStored(locator, stored, credentials, outerKey: outerKey);

  @override
  Future<Uint8List> encode(String locator, KdbxFile file, {String? outerKey}) =>
      tomSecretsEncodeStored(locator, file, outerKey: outerKey);

  /// As the disk's `file:` opener: the document read again, merged three-way
  /// with [file] over [base] when it changed there meanwhile, then written
  /// whole.
  @override
  Future<TomSecretsCommitted> commit(
    String locator,
    KdbxFile file, {
    required Uint8List base,
    required Credentials credentials,
    String? outerKey,
    Uint8List? stored,
  }) async {
    final id = _id(locator);
    final current = await documents.read(id);
    var merged = false;
    var conflicts = 0;
    if (tomSecretsBlobId(current) != tomSecretsBlobId(base)) {
      final result = tomSecretsMergeVaults(
        base: await decode(locator, base, credentials, outerKey: outerKey),
        ours: file,
        theirs: await decode(locator, current, credentials, outerKey: outerKey),
        location: locator,
      );
      merged = true;
      conflicts = result.conflicts.length;
    }
    final written = merged || stored == null
        ? await tomSecretsEncodeStored(
            locator,
            file,
            outerKey: outerKey,
            like: current,
          )
        : stored;
    await documents.write(id, written);
    return TomSecretsCommitted(
      opened: TomSecretsOpenedVault(
        locator: locator,
        file: file,
        stored: written,
        fetchedAt: _clock().toUtc(),
      ),
      merged: merged,
      conflicts: conflicts,
    );
  }

  static Never _desktopOnly() => throw TomSecretsSaveException(
    'unsupported',
    'a phone does not re-key, move or create a file vault: do it in the '
        'desktop app',
  );

  @override
  Future<TomSecretsCommitted> rekey(
    String locator,
    KdbxFile file, {
    required Uint8List base,
    required Uint8List stored,
    String? outerKey,
    Map<String, Uint8List> beside = const {},
  }) async => _desktopOnly();

  /// A document picked on the phone has no folder to read beside it: a
  /// shared vault lives in a repository, not in the phone's Files.
  @override
  Future<({Uint8List bytes, String revision})?> readBeside(
    String locator,
    String name,
  ) async => null;

  @override
  Future<String> writeBeside(
    String locator,
    String name,
    Uint8List bytes, {
    required String? baseRevision,
  }) async => _desktopOnly();

  @override
  Future<Map<String, String>> listBeside(String locator, String folder) async =>
      const {};

  @override
  Future<void> deleteBeside(String locator, List<String> paths) async =>
      _desktopOnly();

  @override
  Future<TomSecretsOpenedVault> move(
    String from,
    String to,
    KdbxFile file, {
    required Uint8List base,
    required Uint8List stored,
    required Credentials credentials,
    String? outerKey,
  }) async => _desktopOnly();

  @override
  Future<TomSecretsOpenedVault> create(
    String locator,
    KdbxFile file, {
    required Uint8List stored,
    required Credentials credentials,
    String? outerKey,
  }) async => _desktopOnly();

  @override
  String? rewrittenHeadOf(String locator) => null;

  @override
  Future<TomSecretsCommitted> resolveRewritten(
    String locator, {
    required bool takeRemote,
  }) => throw StateError('a file: vault has no branch to answer for');

  @override
  void drop() {}
}
