// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// How the app reaches the secrets service: the admin connection and the
/// host that starts, attaches to and claims the service (part-app, "How it
/// works with the service"). The desktop implements it over
/// `tom_secrets_client`'s admin library; a test hands in a fake.
library;

import 'dart:typed_data';

import 'package:tom_secrets_client/admin.dart' show TomSecretsUnlockBundle;
import 'package:tom_secrets_core/tom_secrets_core.dart' show TomSecretsFirstRun;

/// An authenticated admin connection (protocol.md 6).
abstract interface class TomSecretsAdminChannel {
  /// Sends [op] with [args] and answers the answer message; an `error`
  /// answer throws the admin library's `TomSecretsAdminException`.
  ///
  /// A request sent in parts (a large vault's `save` over the admin
  /// socket) reports [onProgress] as it is written: the bytes sent so far
  /// and the bytes in all. A channel that sends nothing in parts (the
  /// phone's engine, in the app's own process) never calls it.
  Future<Map<String, Object?>> request(
    String op, [
    Map<String, Object?> args = const {},
    void Function(int sent, int total)? onProgress,
  ]);

  /// The events after `subscribe`; the stream closes when the connection
  /// ends (the service stopped or died).
  Stream<Map<String, Object?>> get events;

  /// Unlocks [vault] with the OS unlock's key [bundle] (`unlock {vault,
  /// bundle}`, protocol.md 6.4), sealed under this connection's bundle key;
  /// throws the admin library's `TomSecretsAdminException`.
  Future<void> unlockWithBundle(String vault, TomSecretsUnlockBundle bundle);

  /// Closes the connection.
  Future<void> close();
}

/// What attaching to (or starting, or claiming) the service came to.
sealed class TomSecretsAttach {
  const TomSecretsAttach();
}

/// Attached: [channel] is authenticated.
final class TomSecretsAttached extends TomSecretsAttach {
  /// An attached [channel].
  const TomSecretsAttached(this.channel);

  /// The admin connection.
  final TomSecretsAdminChannel channel;
}

/// No service runs for this user.
final class TomSecretsNoService extends TomSecretsAttach {
  /// No service.
  const TomSecretsNoService();
}

/// A service runs, but this device holds no admin key it accepts (started by
/// `tsm` over SSH, or claimed since by another admin): only a `claim` with
/// the master password attaches (DP-16).
final class TomSecretsClaimNeeded extends TomSecretsAttach {
  /// A claim is needed.
  const TomSecretsClaimNeeded();
}

/// This machine is not set up: no service runs and the data directory holds
/// no `bootstrap.yaml`. The app opens the First run wizard.
final class TomSecretsNotSetUp extends TomSecretsAttach {
  /// Not set up.
  const TomSecretsNotSetUp();
}

/// The service cannot be started: no service executable, or a bootstrap
/// file it cannot read.
final class TomSecretsCannotStart extends TomSecretsAttach {
  /// Not startable, with [message] saying what is missing.
  const TomSecretsCannotStart(this.message);

  /// What is missing, for the user.
  final String message;
}

/// Starting the service failed.
final class TomSecretsServiceStartFailed extends TomSecretsAttach {
  /// A start that failed with [message].
  const TomSecretsServiceStartFailed(this.message);

  /// Why, for the user.
  final String message;
}

/// What answers on the admin endpoint is not this user's service
/// (protocol.md 6.0): nothing was sent, and no master password is asked
/// for.
final class TomSecretsServiceUntrusted extends TomSecretsAttach {
  /// An endpoint refused for [reason] (`owner`, `mode`, `peer_user`,
  /// `peer_executable`), [message] saying what is wrong.
  const TomSecretsServiceUntrusted(this.reason, this.message);

  /// The admin library's `details.reason`.
  final String? reason;

  /// What is wrong, for the user.
  final String message;
}

/// Starts, attaches to and claims the service of this user.
abstract interface class TomSecretsServiceHost {
  /// Attaches with the admin key the device keychain keeps for the running
  /// service's start: [TomSecretsAttached], [TomSecretsNoService] (or
  /// [TomSecretsNotSetUp] when the machine has no bootstrap either),
  /// [TomSecretsClaimNeeded], or [TomSecretsServiceUntrusted] when what
  /// answers there is not this user's service (checked before a claim is
  /// offered).
  Future<TomSecretsAttach> attach();

  /// Starts the service (the admin key handed over and kept in the keychain)
  /// and attaches; [TomSecretsNotSetUp] without a bootstrap.
  Future<TomSecretsAttach> start();

  /// Claims the running service with the master [password] (and
  /// [keyFile]); the new admin key is kept in the keychain. Throws the admin
  /// library's `TomSecretsAdminException` (`denied`, reason `bad_password`)
  /// for a wrong password, and `service_untrusted` (nothing sent) when what
  /// answers is not this user's service.
  Future<TomSecretsAttach> claim(String password, {Uint8List? keyFile});

  /// The first run of this machine: its data directory and the device
  /// keychain, where the First run wizard writes (part-app, First run).
  Future<TomSecretsFirstRun> firstRun();

  /// The service this host attached to was stopped (`shutdown`): its admin
  /// key leaves the keychain.
  Future<void> serviceStopped();
}
