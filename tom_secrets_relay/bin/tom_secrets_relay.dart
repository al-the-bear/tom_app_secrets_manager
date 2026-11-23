// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The relay server: `tom_secrets_relay [config=<file>] [port=<n>] ...`.
///
/// The configuration file (`config=`, `TSM_RELAY_CONFIG`, or `relay.yaml`
/// in the working directory) holds `tom_core_server`'s keys and the
/// relay's own under `relay:`; the environment and `key=value` arguments
/// override it.
///
/// This file is the reflection root (`build.yaml`): regenerate
/// `tom_secrets_relay.reflection.dart` with `./reflection_generation.sh`
/// after changing a reflected type.
library;

import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

import 'tom_secrets_relay.reflection.dart';

Future<void> main(List<String> args) async {
  initializeReflection();
  tomSecretsRelayInitialize(configFile: tomSecretsRelayConfigFile(args));
  final configuration = TomSecretsRelayServerConfiguration(args);
  tomLog.setLogLevelByName(configuration.logLevel);
  await TomSecretsRelayApp.start(configuration);
}
