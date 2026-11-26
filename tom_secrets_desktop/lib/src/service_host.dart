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
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsFirstRun, TomSecretsPqcIdentityCrypto;
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
    void Function(int sent, int total)? onProgress,
  ]) => client.request(op, args, onProgress);

  @override
  Stream<Map<String, Object?>> get events => client.events;

  @override
  Future<void> unlockWithBundle(String vault, TomSecretsUnlockBundle bundle) =>
      client.unlockWithBundle(vault, bundle);

  @override
  Future<void> close() => client.close();
}

/// The desktop's [TomSecretsServiceHost].
final class TomSecretsDesktopServiceHost
    implements TomSecretsServiceIdentityHost {
  /// A host for this user's service: [environment] (default the process's;
  /// `TSM_RUNTIME_DIR`, `TSM_DATA_DIR`, `TSM_SERVICE`), the service
  /// executable beside [executableDirectory] (default the app's), the
  /// keychain [keychain] (default the OS keychain, when it answers).
  TomSecretsDesktopServiceHost({
    Map<String, String>? environment,
    String? executableDirectory,
    TomSecretStore? keychain,
    this.endpointInspector = const TomSecretsSystemEndpointInspector(),
    TomSecretsServicePins? pins,
  }) : _pins = pins,
       environment = environment ?? Platform.environment,
       executableDirectory =
           executableDirectory ?? File(Platform.resolvedExecutable).parent.path,
       _keychain = keychain;

  /// The environment the service is found and started with.
  final Map<String, String> environment;

  /// Where the service executable is looked for when `TSM_SERVICE` names
  /// none.
  final String executableDirectory;

  /// Reads who answers on the admin endpoint (protocol.md 6.0).
  final TomSecretsEndpointInspector endpointInspector;

  /// The check every admin connection runs before it sends anything
  /// (protocol.md 6.0): the service expected is `tom_secrets_service`
  /// beside the app, the one in its distribution's `tsm/bin`, or the one
  /// `TSM_SERVICE` names.
  TomSecretsServiceTrust get serviceTrust => TomSecretsServiceTrust(
    executables: tomSecretsExpectedServiceExecutables(
      ownExecutable:
          '$executableDirectory${Platform.pathSeparator}'
          '$tomSecretsAppExecutable',
      environment: environment,
    ),
    inspector: endpointInspector,
    identity: identityTrust,
  );

  TomSecretsServicePins? _pins;

  /// The pins of the services this user's app and `tsm` know (protocol.md
  /// 6.1): the file both share.
  TomSecretsServicePins get pins => _pins ??= TomSecretsPinFile(
    File(tomSecretsPinFile(environment: environment)),
  );

  /// What the service's identity key is checked with: the pins, and the
  /// primitives in this process.
  late final TomSecretsIdentityTrust identityTrust = TomSecretsIdentityTrust(
    pins: pins,
    crypto: const TomSecretsPqcIdentityCrypto(),
  );

  /// What a refusal to send anything came to: an endpoint that is not this
  /// user's service or not pinned yet, or a service whose key changed;
  /// null for any other error.
  static TomSecretsAttach? _refused(TomSecretsAdminException e) =>
      switch (e.kind) {
        tomSecretsServiceUntrusted => TomSecretsServiceUntrusted(
          e.details['reason'] as String?,
          e.message,
          words: e.details['words'] as String?,
        ),
        tomSecretsServiceKeyChanged => TomSecretsServiceKeyChanged(
          e.message,
          pinned: e.details['pinned'] as String?,
          presented: e.details['presented'] as String?,
        ),
        _ => null,
      };

  @override
  Future<TomSecretsAttach> trustService(String words) async {
    final rt = runtime;
    final TomSecretsServiceIdentity presented;
    try {
      presented = await TomSecretsAdminClient.presentedIdentity(
        rt,
        trust: serviceTrust,
      );
    } on TomSecretsAdminException catch (e) {
      if (e.kind == 'not_running') return const TomSecretsNoService();
      final refused = _refused(e);
      if (refused != null) return refused;
      rethrow;
    }
    // What answers now may not be what showed the words.
    if (!tomSecretsIdentityNamedBy(words, presented.publicKey)) {
      return TomSecretsServiceKeyChanged(
        'the service presents another identity than the one compared',
        pinned: words,
        presented: presented.words,
      );
    }
    await pins.pin(
      identityTrust.host,
      rt.directory,
      presented.publicKey,
      TomSecretsPinSource.trust,
    );
    return attach();
  }

  @override
  Future<TomSecretsAttach> forgetServicePin() async {
    await pins.remove(identityTrust.host, runtime.directory);
    return attach();
  }

  @override
  Future<void> pinDevices(List<Object?> devices) async {
    await tomSecretsPinDevices(pins, devices);
  }

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

  /// The service installed on its own for this user (`tsm install`), or
  /// null.
  TomSecretsUserInstall? get userInstall =>
      TomSecretsUserInstall.read(environment: environment);

  /// Where the service executable is: `TSM_SERVICE`, else the service
  /// installed on its own for this user ([userInstall], which keeps running
  /// when the app quits, is ended or is updated), else the app's own
  /// ([distributionServiceExecutable]).
  String get serviceExecutable {
    final named = environment['TSM_SERVICE'];
    if (named != null) return named;
    return userInstall?.serviceExecutable ?? distributionServiceExecutable;
  }

  /// The service the app brings: the first of `tom_secrets_service` beside
  /// the app and the one in the app's distribution (`tsm/bin`,
  /// `tomSecretsServiceCandidates`) that exists, else the one beside the app
  /// (for the message saying it is missing).
  String get distributionServiceExecutable {
    final candidates = tomSecretsServiceCandidates(
      executableDirectory,
      operatingSystem: Platform.operatingSystem,
    );
    return candidates.firstWhere(
      (c) => File(c).existsSync(),
      orElse: () => candidates.first,
    );
  }

  /// `tsm` beside the service executable (the installed one, the
  /// distribution's `tsm/bin`, or a development layout), where the git
  /// integration links its helper.
  String get tsmExecutable => _tsmBeside(serviceExecutable);

  /// `tsm` beside the app's own service, which installs and removes the
  /// service installed on its own.
  String get distributionTsmExecutable =>
      _tsmBeside(distributionServiceExecutable);

  static String _tsmBeside(String service) {
    final cut = service.lastIndexOf(RegExp(r'[/\\]'));
    final dir = cut < 0 ? '.' : service.substring(0, cut);
    return '$dir${Platform.pathSeparator}tsm${Platform.isWindows ? '.exe' : ''}';
  }

  /// The browser host beside the service executable, where the service
  /// recognises it and the browsers' manifests name it (part-browser).
  String get browserHostExecutable => tomSecretsBrowserHostBeside(
    serviceExecutable,
    operatingSystem: Platform.operatingSystem,
  );

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
      // A claim is offered (and the master password asked for) only for an
      // endpoint that is this user's service.
      try {
        await TomSecretsAdminClient.checkService(rt, trust: serviceTrust);
      } on TomSecretsAdminException catch (e) {
        if (e.kind == 'not_running') return const TomSecretsNoService();
        final refused = _refused(e);
        if (refused != null) return refused;
        rethrow;
      }
      return const TomSecretsClaimNeeded();
    }
    try {
      final client = await TomSecretsAdminClient.connect(
        rt,
        stored,
        client: tomSecretsAppClient,
        trust: serviceTrust,
      );
      _attachedStart = start;
      await _pruneOthers(keyring, start);
      return TomSecretsAttached(TomSecretsAdminClientChannel(client));
    } on TomSecretsAdminException catch (e) {
      if (e.kind == 'not_running') return const TomSecretsNoService();
      final refused = _refused(e);
      if (refused != null) return refused;
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
      case TomSecretsStarted(:final adminKey, :final identity):
        final start = (await runtime.readInfo())?['start'];
        if (start is int) await _keep(start, adminKey);
        // First contact (protocol.md 6.1): the process this app started
        // said its identity key on its standard output; it is pinned, and
        // every connection from now on checks it.
        if (identity != null) {
          await pins.pin(
            identityTrust.host,
            runtime.directory,
            identity,
            TomSecretsPinSource.start,
          );
        }
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
      trust: serviceTrust,
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

/// Runs a program: [executable] with [arguments] in [environment].
typedef TomSecretsProgramRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments,
      Map<String, String> environment,
    );

Future<ProcessResult> _runProgram(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
) => Process.run(executable, arguments, environment: environment);

/// The desktop's [TomSecretsServiceInstaller]: the `tsm install` and `tsm
/// uninstall` of the app's distribution (tsm_d12), the app named in the
/// install record so the installed service admits it.
final class TomSecretsDesktopServiceInstaller
    implements TomSecretsServiceInstaller {
  /// The installer of [host]'s service; [appExecutable] (default the app's)
  /// is recorded as an admin, [run] runs `tsm` (tests hand in their own).
  TomSecretsDesktopServiceInstaller(
    this.host, {
    String? appExecutable,
    String? operatingSystem,
    TomSecretsProgramRunner run = _runProgram,
  }) : appExecutable = appExecutable ?? Platform.resolvedExecutable,
       operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _run = run;

  /// The host whose service and environment are installed.
  final TomSecretsDesktopServiceHost host;

  /// The app recorded in the install.
  final String appExecutable;

  /// The OS (Windows: the service the app starts ends with its package).
  final String operatingSystem;

  final TomSecretsProgramRunner _run;

  bool get _packaged =>
      operatingSystem == 'windows' &&
      appExecutable.toLowerCase().contains(r'\windowsapps\');

  @override
  Future<TomSecretsServiceInstallState> state() async {
    final install = host.userInstall;
    return TomSecretsServiceInstallState(
      installed: install != null,
      directory: install?.directory,
      version: install == null || install.version.isEmpty
          ? null
          : install.version,
      endsWithApp: install == null && _packaged,
    );
  }

  /// Names this app in the install record when the service is installed
  /// and the record lacks it (the app moved, or another app installed it);
  /// the installed service admits it from its next start.
  void recordApp() {
    final install = host.userInstall;
    if (install == null || install.apps.contains(appExecutable)) return;
    try {
      install.withApp(appExecutable).writeRecord();
    } on FileSystemException {
      // Not writable: an app that is not named stays a claim's.
    }
  }

  Future<void> _tsm(List<String> arguments) async {
    final tsm = host.distributionTsmExecutable;
    if (!File(tsm).existsSync()) {
      throw TomSecretsServiceInstallException(
        'This app brings no tsm to install the service with ($tsm).',
      );
    }
    final ProcessResult result;
    try {
      result = await _run(tsm, arguments, host.environment);
    } on ProcessException catch (e) {
      throw TomSecretsServiceInstallException('tsm: ${e.message}');
    }
    if (result.exitCode != 0) {
      final text = '${result.stderr}'.trim();
      throw TomSecretsServiceInstallException(
        text.isEmpty ? 'tsm exited ${result.exitCode}' : text,
      );
    }
  }

  @override
  Future<TomSecretsServiceInstallState> install() async {
    await _tsm([
      'install',
      '--service',
      host.distributionServiceExecutable,
      '--app',
      appExecutable,
    ]);
    return state();
  }

  @override
  Future<TomSecretsServiceInstallState> uninstall() async {
    await _tsm(['uninstall']);
    return state();
  }
}

/// Whether [store] answers (the OS keychain over SSH may not).
Future<bool> tomSecretsKeychainAvailable(TomSecretStore store) async =>
    store is! TomSecretStoreAvailability ||
    await (store as TomSecretStoreAvailability).isAvailable();
