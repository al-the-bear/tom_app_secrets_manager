// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// How the app reaches the secrets service: the admin connection and the
/// host that starts, attaches to and claims the service (part-app, "How it
/// works with the service"). The desktop implements it over
/// `tom_secrets_client`'s admin library; a test hands in a fake.
library;

import 'dart:typed_data';

/// An authenticated admin connection (protocol.md 6).
abstract interface class TomSecretsAdminChannel {
  /// Sends [op] with [args] and answers the answer message; an `error`
  /// answer throws the admin library's `TomSecretsAdminException`.
  Future<Map<String, Object?>> request(
    String op, [
    Map<String, Object?> args = const {},
  ]);

  /// The events after `subscribe`; the stream closes when the connection
  /// ends (the service stopped or died).
  Stream<Map<String, Object?>> get events;

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

/// The service cannot be started: no bootstrap file (the first run has not
/// set the machine up) or no service executable.
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

/// Starts, attaches to and claims the service of this user.
abstract interface class TomSecretsServiceHost {
  /// Attaches with the admin key the device keychain keeps for the running
  /// service's start: [TomSecretsAttached], [TomSecretsNoService] or
  /// [TomSecretsClaimNeeded].
  Future<TomSecretsAttach> attach();

  /// Starts the service (the admin key handed over and kept in the keychain)
  /// and attaches.
  Future<TomSecretsAttach> start();

  /// Claims the running service with the master [password] (and
  /// [keyFile]); the new admin key is kept in the keychain. Throws the admin
  /// library's `TomSecretsAdminException` (`denied`, reason `bad_password`)
  /// for a wrong password.
  Future<TomSecretsAttach> claim(String password, {Uint8List? keyFile});
}
