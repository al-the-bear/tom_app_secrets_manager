// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** Starting and stopping a relay: the server's configuration (its
/// `relay:` section beside `tom_core_server`'s keys), the endpoints and
/// `/health` / `/ready` registered, the guard before every route, the
/// expiry job on the kernel's scheduler (in-memory job store, one node).
library;

import 'dart:async';
import 'dart:io';

import 'package:tom_core_server/tom_core_server.dart';

import 'config.dart';
import 'relay_api.dart';
import 'relay_state.dart';

/// The port a relay listens on when nothing else is configured.
const int tomSecretsRelayDefaultPort = 47910;

/// The relay's server configuration: `tom_core_server`'s keys (`port`,
/// `host`, `logLevel`, ...) from the configuration file, the environment
/// and the arguments, and the relay's own under `relay`.
@tomReflector
class TomSecretsRelayServerConfiguration extends TomBaseServerConfiguration {
  /// The configuration from [args] (and the configuration file the
  /// resource provider holds). Plain HTTP: the reverse proxy terminates TLS.
  TomSecretsRelayServerConfiguration(super.args) {
    if (appId.isEmpty) appId = 'tom_secrets_relay';
    if (port == 0) port = tomSecretsRelayDefaultPort;
    noSsl = true;
    isolateLogging = false;
    isolateCount = 1;
  }

  /// The `relay:` section of the configuration file, taken out of the
  /// resources before they are installed
  /// ([tomSecretsRelayInstallConfiguration]), so `tom_core_server`'s
  /// configuration does not take it for a misspelled key of its own.
  static Map<Object?, Object?> relaySection = const {};

  /// The relay's settings (`relay:`); a test or a program may replace them.
  TomSecretsRelayConfig relaySettings = const TomSecretsRelayConfig();

  @override
  void setValues(Map<String, dynamic> values) {
    tomReflectionInfo.setValues<TomSecretsRelayServerConfiguration>(
      this,
      values,
    );
    final section = values['relay'];
    relaySettings = TomSecretsRelayConfig.fromMap(
      section is Map ? section : relaySection,
    );
  }
}

/// The expiry job's body.
final class _ExpireCommand extends TomCommand {
  _ExpireCommand(this.state);

  final TomSecretsRelayState state;

  @override
  Future<Object?> execute() async {
    await state.expire();
    return null;
  }
}

/// A running relay.
final class TomSecretsRelayApp {
  TomSecretsRelayApp._(this.state, this.server, this.http, this._scheduler);

  /// Starts a relay with [configuration] (reflection initialised by the
  /// caller), the time read from [clock].
  static Future<TomSecretsRelayApp> start(
    TomSecretsRelayServerConfiguration configuration, {
    DateTime Function()? clock,
  }) async {
    final settings = configuration.relaySettings;
    final state = TomSecretsRelayState(settings, clock: clock);
    TomBean.withType<TomSecretsRelayServer>(TomSecretsRelayServer(state));
    TomBean.withType<TomHealthServer>(TomHealthServer());
    configuration.authenticationMiddleware = state.guardMiddleware();
    // Every relay endpoint declares its access (public); anything the
    // framework would mount without a declaration stays closed (the guard
    // answers 404 for it besides).
    TomResourceKeyProtection.globalSettingProtectionDefault = true;
    if (settings.mode == TomSecretsRelayMode.token && settings.tokens.isEmpty) {
      tomLog.warn(
        'relay: token mode without instance tokens: every mailbox put and '
        'approval link is refused. Set relay.tokens (one token per team or '
        'user), or relay.mode: open.',
      );
    }
    final scheduler = TomScheduler(
      store: TomMemoryJobStore(),
      dispatcher: const TomInlineJobDispatcher(),
      ownerId: 'tom_secrets_relay',
    );
    scheduler.register(
      TomJobDefinition(
        name: 'relay.expire',
        schedule: TomIntervalSchedule(settings.expiryInterval),
        body: (_) => _ExpireCommand(state),
      ),
    );
    await scheduler.start();
    final server = TomServer(configuration);
    final HttpServer http;
    try {
      http = await server.start();
    } on Object {
      await scheduler.close();
      rethrow;
    }
    tomLog.info(
      'relay: listening on port ${http.port} (${settings.mode.name} mode, '
      '${settings.tokens.length} instance tokens)',
    );
    return TomSecretsRelayApp._(state, server, http, scheduler);
  }

  /// What it holds.
  final TomSecretsRelayState state;

  /// The `tom_core_server` server.
  final TomServer server;

  /// The bound socket.
  final HttpServer http;

  final TomScheduler _scheduler;

  /// The port it listens on.
  int get port => http.port;

  /// Stops it: the channels closed, the socket closed.
  Future<void> stop() async {
    await _scheduler.close();
    state.close();
    await http.close(force: true);
  }
}

/// The relay's environment, the root of its one-level hierarchy.
const TomEnvironment tomSecretsRelayEnvironment = TomEnvironment('prod');

/// Sets the platform and the runtime environment up (once per process,
/// after `initializeReflection()`), and installs the configuration file
/// [configFile] (null: none) as the server's configuration resources.
void tomSecretsRelayInitialize({String? configFile}) {
  TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);
  TomRuntime.addEnvironment(tomSecretsRelayEnvironment);
  TomRuntime.setRootEnvironment(tomSecretsRelayEnvironment);
  TomRuntime.setCurrentEnvironment('prod', 'prod');
  TomRuntime.getCurrentEnvironment().initialize();
  TomRuntime.initializePlatform();
  final resources = <String, dynamic>{};
  if (configFile != null) {
    final file = File(configFile);
    if (!file.existsSync()) {
      throw StateError(
        'relay: the configuration file ${file.absolute.path} does not exist',
      );
    }
    mergeMapsOneSided(resources, TomYaml.loadYamlFile(configFile));
  }
  tomSecretsRelayInstallConfiguration(resources);
}

/// Installs [resources] (a configuration file's content) as the server's
/// configuration resources, its `relay:` section kept apart for
/// [TomSecretsRelayServerConfiguration.relaySection].
void tomSecretsRelayInstallConfiguration(Map<String, dynamic> resources) {
  final rest = {...resources};
  final relay = rest.remove('relay');
  TomSecretsRelayServerConfiguration.relaySection = relay is Map
      ? relay
      : const {};
  TomServerConfigResourceProvider.setServerConfigProvider(
    TomServerConfigResourceProvider.from(rest),
  );
}

/// The configuration file [args] name (`config=<path>`), else the
/// environment's `TSM_RELAY_CONFIG`, else `relay.yaml` when it exists.
String? tomSecretsRelayConfigFile(List<String> args) {
  for (final a in args) {
    if (a.startsWith('config=')) return a.substring('config='.length);
  }
  final env = Platform.environment['TSM_RELAY_CONFIG'];
  if (env != null && env.isNotEmpty) return env;
  return File('relay.yaml').existsSync() ? 'relay.yaml' : null;
}

/// The address a health check asks: `/health` on [configuration]'s port,
/// on its host (the loopback when it listens on every address).
Uri tomSecretsRelayHealthUrl(TomSecretsRelayServerConfiguration configuration) {
  final host = configuration.host;
  final any =
      host.isEmpty ||
      host == '0.0.0.0' ||
      host == '::' ||
      configuration.listenToAnyIp == true;
  return Uri(
    scheme: 'http',
    host: any ? '127.0.0.1' : host,
    port: configuration.port,
    path: '/health',
  );
}

/// The container's health check (`tom_secrets_relay health`): asks [url]
/// and answers 0 when it says 200 within [timeout], else 1, saying why on
/// [err]. A container image on `scratch` has no curl, so the executable
/// checks itself; `/health` is not counted against the address limits.
Future<int> tomSecretsRelayHealthCheck(
  Uri url, {
  Duration timeout = const Duration(seconds: 5),
  StringSink? err,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>();
    if (response.statusCode == HttpStatus.ok) return 0;
    err?.writeln('relay health: $url answered ${response.statusCode}');
    return 1;
  } on Object catch (e) {
    err?.writeln('relay health: $url: $e');
    return 1;
  } finally {
    client.close(force: true);
  }
}
