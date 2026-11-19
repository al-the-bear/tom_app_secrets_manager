// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The integrations the app installs (Settings › Integrations): the ssh
/// block naming the service's agent and the git credential helper
/// (part-os-integration), written by the client library's
/// `TomSecretsIntegrations` in marked blocks; and the browsers'
/// native-messaging manifests naming the browser host (part-browser),
/// written by `TomSecretsBrowserHosts`. At every start the app checks that
/// the installed ones still name this machine's agent, helper and host, and
/// repairs them.
library;

import 'package:tom_secrets_client/admin.dart';

import '../ports/desktop_ports.dart';
import 'service_connection.dart';

/// The integrations of this user, with the agent endpoint the service
/// reports (`statusReport.agent`), or null when the host gives no paths.
Future<TomSecretsIntegrations?> tomSecretsIntegrationsOf(
  TomSecretsHost host,
  TomSecretsServiceConnection connection,
) async {
  final paths = host.integrationPaths;
  if (paths == null) return null;
  String? agent;
  try {
    final status = await connection.request('status');
    final endpoint = status['agent'];
    if (endpoint is Map) {
      agent = (endpoint['socket'] ?? endpoint['pipe']) as String?;
    }
  } on TomSecretsAdminException {
    agent = null;
  }
  return TomSecretsIntegrations(
    home: paths.home,
    agentEndpoint: agent,
    tsmExecutable: paths.tsmExecutable,
  );
}

/// The check at every start: repairs the installed integrations that no
/// longer name this machine's agent or helper; answers those repaired
/// (empty when nothing was wrong, or the host gives no paths).
Future<List<TomSecretsIntegration>> tomSecretsCheckIntegrations(
  TomSecretsHost host,
  TomSecretsServiceConnection connection,
) async {
  final integrations = await tomSecretsIntegrationsOf(host, connection);
  if (integrations == null) return const [];
  return integrations.repair();
}

/// The browsers' manifests of this user, naming the host's browser host, or
/// null when the host gives no browser host.
TomSecretsBrowserHosts? tomSecretsBrowserHostsOf(TomSecretsHost host) {
  final paths = host.integrationPaths;
  final browserHost = paths?.browserHostExecutable;
  if (paths == null || browserHost == null) return null;
  return TomSecretsBrowserHosts(home: paths.home, hostExecutable: browserHost);
}

/// The check at every start for the browsers: rewrites each installed
/// manifest naming another host (the app moved or was updated); answers the
/// browsers repaired.
Future<List<TomSecretsBrowser>> tomSecretsCheckBrowserHosts(
  TomSecretsHost host,
) async => await tomSecretsBrowserHostsOf(host)?.repair() ?? const [];
