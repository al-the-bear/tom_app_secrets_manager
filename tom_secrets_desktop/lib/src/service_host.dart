// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Starting, attaching to and claiming the secrets service on a desktop
/// (part-app, "How it works with the service"), over the admin library tsm
/// uses: the runtime directory, `tomSecretsStartService` with the admin-key
/// handover, the admin key in the OS keychain under the same handle tsm uses
/// (`tsm.admin.<start>`), so the app and tsm share it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tom_core_storage/io.dart' show TomDesktopSecretStore;
import 'package:tom_core_storage/settings.dart'
    show TomSecretStore, TomSecretStoreAvailability, TomSecretStoreException;
import 'package:tom_secrets_client/admin.dart';
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

  /// Where the service executable is: `TSM_SERVICE`, else
  /// `tom_secrets_service` beside the app.
  String get serviceExecutable =>
      environment['TSM_SERVICE'] ??
      '$executableDirectory${Platform.pathSeparator}tom_secrets_service'
          '${Platform.isWindows ? '.exe' : ''}';

  @override
  Future<TomSecretsAttach> attach() async {
    final rt = runtime;
    final info = await rt.readInfo();
    final start = info?['start'];
    if (start is! int) return const TomSecretsNoService();
    final keychain = await _store();
    String? stored;
    try {
      stored = await keychain?.read(tomSecretsAdminKeyHandle(start));
    } on TomSecretStoreException {
      stored = null;
    }
    if (stored == null) return const TomSecretsClaimNeeded();
    try {
      return TomSecretsAttached(
        TomSecretsAdminClientChannel(
          await TomSecretsAdminClient.connect(
            rt,
            base64.decode(stored),
            client: tomSecretsAppClient,
          ),
        ),
      );
    } on TomSecretsAdminException catch (e) {
      if (e.kind == 'not_running') return const TomSecretsNoService();
      // The key was revoked by a claim since: only a claim attaches.
      return const TomSecretsClaimNeeded();
    }
  }

  @override
  Future<TomSecretsAttach> start() async {
    final bootstrap = tomSecretsBootstrapPath(environment: environment);
    if (!await File(bootstrap).exists()) {
      return TomSecretsCannotStart(
        'No bootstrap file at $bootstrap: this machine is not set up yet '
        '(the first run, or tsm, writes it).',
      );
    }
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
    if (start is int) await _keep(start, key);
    return TomSecretsAttached(TomSecretsAdminClientChannel(client));
  }

  Future<void> _keep(int start, Uint8List key) async {
    final keychain = await _store();
    try {
      await keychain?.write(tomSecretsAdminKeyHandle(start), base64.encode(key));
    } on TomSecretStoreException {
      // Without the keychain the next start claims again (DP-22).
    }
  }
}

/// Whether [store] answers (the OS keychain over SSH may not).
Future<bool> tomSecretsKeychainAvailable(TomSecretStore store) async =>
    store is! TomSecretStoreAvailability ||
    await (store as TomSecretStoreAvailability).isAvailable();
