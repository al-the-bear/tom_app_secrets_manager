// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The developer-tool integrations the app installs (part-os-integration,
/// "Installing and checking"; Settings › Integrations): the ssh block naming
/// the service's agent and the git credential helper, written by the client
/// library's `TomSecretsIntegrations` in marked blocks. At every start the
/// app checks that the installed ones still name this machine's agent and
/// helper, and repairs them.
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
