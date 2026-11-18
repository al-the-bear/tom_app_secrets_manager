// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The service host of the mobile app: no service runs, so attaching hands
/// the screens the in-app engine; there is nothing to start, stop or claim.
library;

import 'dart:typed_data';

import 'package:tom_secrets_core/tom_secrets_core.dart' show TomSecretsFirstRun;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'mobile_engine.dart';

/// [TomSecretsServiceHost] over [engine].
final class TomSecretsMobileServiceHost implements TomSecretsServiceHost {
  /// The host of [engine].
  TomSecretsMobileServiceHost(this.engine);

  /// The engine.
  final TomSecretsMobileEngine engine;

  @override
  Future<TomSecretsAttach> attach() async => TomSecretsAttached(engine);

  @override
  Future<TomSecretsAttach> start() => attach();

  @override
  Future<TomSecretsAttach> claim(String password, {Uint8List? keyFile}) =>
      attach();

  /// A phone is set up by pairing before the app opens (the mobile setup
  /// screen), never by the desktop's First run wizard.
  @override
  Future<TomSecretsFirstRun> firstRun() =>
      Future.error(UnsupportedError('a phone is set up by pairing'));

  @override
  Future<void> serviceStopped() async {}
}
