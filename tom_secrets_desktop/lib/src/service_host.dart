// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Starting, attaching to and claiming the secrets service on a desktop
/// (part-app, "How it works with the service"), over the admin library tsm
/// uses: the runtime directory, `tomSecretsStartService` with the admin-key
/// handover, the admin key in the OS keychain under the same handle tsm uses
/// (`tsm.admin.<start>`), so the app and tsm share it.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:tom_core_storage/io.dart' show TomDesktopSecretStore;
import 'package:tom_core_storage/settings.dart'
    show TomSecretStore, TomSecretStoreAvailability, TomSecretStoreException;
import 'package:tom_secrets_client/admin.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart' show TomSecretsFirstRun;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// How the app names itself to the service (shown, never trusted: the
/// service measures the executable).
const Map<String, Object?> tomSecretsAppClient = {
  'name': 'Tom Secrets Manager',
};

/// [TomSecretsAdminChannel] over the admin library's client.
final class TomSecretsAdminClientChannel implements TomSecretsAdminChannel {
  /// The channel of [client].
  TomSecretsAdminClientChannel(this.client);

  /// The admin client.
  final TomSecretsAdminClient client;

  @override
  Future<Map<String, Object?>> request(
    String op, [
    Map<String, Object?> args = const {},
  ]) => client.request(op, args);

  @override
  Stream<Map<String, Object?>> get events => client.events;

  @override
  Future<void> close() => client.close();
}

/// The desktop's [TomSecretsServiceHost].
final class TomSecretsDesktopServiceHost implements TomSecretsServiceHost {
  /// A host for this user's service: [environment] (default the process's;
  /// `TSM_RUNTIME_DIR`, `TSM_DATA_DIR`, `TSM_SERVICE`), the service
  /// executable beside [executableDirectory] (default the app's), the
  /// keychain [keychain] (default the OS keychain, when it answers).
  TomSecretsDesktopServiceHost({
    Map<String, String>? environment,
    String? executableDirectory,
    TomSecretStore? keychain,
  }) : environment = environment ?? Platform.environment,
       executableDirectory =
           executableDirectory ?? File(Platform.resolvedExecutable).parent.path,
       _keychain = keychain;

  /// The environment the service is found and started with.
  final Map<String, String> environment;

  /// Where the service executable is looked for when `TSM_SERVICE` names
  /// none.
  final String executableDirectory;

  TomSecretStore? _keychain;
  bool _keychainChecked = false;

  /// The runtime directory of this user's service.
  TomSecretsRuntime get runtime =>
      TomSecretsRuntime.current(environment: environment);

  Future<TomSecretStore?> _store() async {
    if (_keychainChecked || _keychain != null) return _keychain;
    _keychainChecked = true;
    final store = TomDesktopSecretStore(service: tomSecretsKeychainService);
    _keychain = await store.isAvailable() ? store : null;
    return _keychain;
  }

  /// Where the service executable is: `TSM_SERVICE`, else the first of
  /// `tom_secrets_service` beside the app and the one in the app's
  /// distribution (`tsm/bin`, `tomSecretsServiceCandidates`) that exists,
  /// else the one beside the app (for the message saying it is missing).
  String get serviceExecutable {
    final named = environment['TSM_SERVICE'];
    if (named != null) return named;
    final candidates = tomSecretsServiceCandidates(
      executableDirectory,
      operatingSystem: Platform.operatingSystem,
    );
    return candidates.firstWhere(
      (c) => File(c).existsSync(),
      orElse: () => candidates.first,
    );
  }

  @override
  Future<TomSecretsAttach> attach() async {
    final rt = runtime;
    final info = await rt.readInfo();
    final start = info?['start'];
    if (start is! int) {
      return await File(
            tomSecretsBootstrapPath(environment: environment),
          ).exists()
          ? const TomSecretsNoService()
          : const TomSecretsNotSetUp();
    }
    final keyring = await _keyring();
    Uint8List? stored;
    try {
      stored = await keyring?.keyOf(start);
    } on TomSecretStoreException {
      stored = null;
    }
    if (keyring == null || stored == null) {
      return const TomSecretsClaimNeeded();
    }
    try {
      final client = await TomSecretsAdminClient.connect(
        rt,
        stored,
        client: tomSecretsAppClient,
      );
      _attachedStart = start;
      await _pruneOthers(keyring, start);
      return TomSecretsAttached(TomSecretsAdminClientChannel(client));
    } on TomSecretsAdminException catch (e) {
      if (e.kind == 'not_running') return const TomSecretsNoService();
      // The key was revoked by a claim since: only a claim attaches.
      return const TomSecretsClaimNeeded();
    }
  }

  @override
  Future<TomSecretsAttach> start() async {
    final bootstrap = tomSecretsBootstrapPath(environment: environment);
    if (!await File(bootstrap).exists()) return const TomSecretsNotSetUp();
    final exe = serviceExecutable;
    if (!await File(exe).exists()) {
      return TomSecretsCannotStart(
        'No service executable at $exe (TSM_SERVICE names another).',
      );
    }
    final result = await tomSecretsStartService(
      executable: exe,
      bootstrap: bootstrap,
      environment: environment,
    );
    switch (result) {
      case TomSecretsStarted(:final adminKey):
        final start = (await runtime.readInfo())?['start'];
        if (start is int) await _keep(start, adminKey);
        return attach();
      case TomSecretsAlreadyStarted():
        return attach();
      case TomSecretsStartFailed(:final code, :final message):
        return TomSecretsServiceStartFailed('$code: $message');
    }
  }

  @override
  Future<TomSecretsAttach> claim(String password, {Uint8List? keyFile}) async {
    final rt = runtime;
    final start = (await rt.readInfo())?['start'];
    final (client, key) = await TomSecretsAdminClient.claim(
      rt,
      password: password,
      keyFile: keyFile,
      client: tomSecretsAppClient,
    );
    if (start is int) {
      _attachedStart = start;
      await _keep(start, key);
    }
    return TomSecretsAttached(TomSecretsAdminClientChannel(client));
  }

  @override
  Future<TomSecretsFirstRun> firstRun() async => TomSecretsFirstRun(
    dataDirectory: tomSecretsDataDirectory(environment: environment),
    keychain: await _store(),
  );

  @override
  Future<void> serviceStopped() async {
    final start = _attachedStart;
    final keyring = await _keyring();
    if (start == null || keyring == null) return;
    _attachedStart = null;
    try {
      await keyring.forget(start);
    } on TomSecretStoreException {
      // A key left behind is removed by the next prune.
    }
  }

  /// The start of the service this host last attached to, or null.
  int? _attachedStart;

  /// The admin keys in the keychain, or null without one.
  Future<TomSecretsAdminKeyring?> _keyring() async {
    final keychain = await _store();
    if (keychain == null) return null;
    return TomSecretsAdminKeyring(
      read: keychain.read,
      write: keychain.write,
      delete: keychain.delete,
    );
  }

  /// Keeps [key] for the service started at [start] and removes the keys of
  /// services that are gone.
  Future<void> _keep(int start, Uint8List key) async {
    final keyring = await _keyring();
    if (keyring == null) return;
    try {
      await keyring.keep(start, key);
    } on TomSecretStoreException {
      // Without the keychain the next start claims again (DP-22).
      return;
    }
    await _pruneOthers(keyring, start);
  }

  Future<void> _pruneOthers(TomSecretsAdminKeyring keyring, int start) async {
    try {
      await keyring.pruneOthers(start);
    } on TomSecretStoreException {
      // Tried again the next time a key is kept or used.
    }
  }
}

/// Whether [store] answers (the OS keychain over SSH may not).
Future<bool> tomSecretsKeychainAvailable(TomSecretStore store) async =>
    store is! TomSecretStoreAvailability ||
    await (store as TomSecretStoreAvailability).isAvailable();
