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

  /// Sends [op] with [fields] and the secrets [sealed] (the quick unlock's
  /// PIN and token, protocol.md 6.4), sealed under this connection's bundle
  /// key where it crosses a socket; the answer's fields named in [open]
  /// come back as bytes (the caller wipes them). Throws the admin library's
  /// `TomSecretsAdminException`.
  Future<Map<String, Object?>> requestSealed(
    String op, {
    Map<String, Object?> fields = const {},
    Map<String, List<int>> sealed = const {},
    List<String> open = const [],
  });

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
  /// `peer_executable`, `unpinned`, `no_identity`), [message] saying what
  /// is wrong.
  const TomSecretsServiceUntrusted(this.reason, this.message, {this.words});

  /// The admin library's `details.reason`.
  final String? reason;

  /// What is wrong, for the user.
  final String message;

  /// With `unpinned`: the words of the identity key the service presents,
  /// for the user to compare (protocol.md 6.1).
  final String? words;
}

/// The service presents another identity key than the one this user's
/// programs pinned (protocol.md 6.1): nothing was sent, and there is no
/// going on with it.
final class TomSecretsServiceKeyChanged extends TomSecretsAttach {
  /// A changed key: the words [pinned] and the words [presented].
  const TomSecretsServiceKeyChanged(
    this.message, {
    this.pinned,
    this.presented,
  });

  /// What is wrong, for the user.
  final String message;

  /// The words of the key pinned.
  final String? pinned;

  /// The words of the key the service presents.
  final String? presented;
}

/// A host that checks which service answers by its identity key and keeps
/// the pins (the desktop; a phone runs no service).
abstract interface class TomSecretsServiceIdentityHost
    implements TomSecretsServiceHost {
  /// Pins the key the service presents when its words are [words] (the
  /// user compared them), then attaches; a service presenting other words
  /// is [TomSecretsServiceKeyChanged].
  Future<TomSecretsAttach> trustService(String words);

  /// Forgets the pin of this machine's service (the user set the service
  /// up anew), then attaches: the service is then not pinned, and its
  /// words are compared again.
  Future<TomSecretsAttach> forgetServicePin();

  /// Pins the service keys the primary's device records name ([devices],
  /// the `devices` of `pair.list`) for their hosts.
  Future<void> pinDevices(List<Object?> devices);
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

/// The service installed on its own for this user (`tsm install`): where
/// it is and which version, or not installed.
final class TomSecretsServiceInstallState {
  /// A state: [installed] in [directory] at [version]; [endsWithApp]: the
  /// service the app starts without the install ends with the app (Windows:
  /// the app's MSIX package ends the processes it started).
  const TomSecretsServiceInstallState({
    required this.installed,
    this.directory,
    this.version,
    this.endsWithApp = false,
  });

  /// Whether the service is installed on its own.
  final bool installed;

  /// The install folder.
  final String? directory;

  /// The version installed.
  final String? version;

  /// Whether the service started from the app ends with the app.
  final bool endsWithApp;
}

/// Installs the service on its own for this user, so it keeps running when
/// the app quits, is ended or is updated (the desktop; Settings › This
/// machine › "Run the service on its own").
abstract interface class TomSecretsServiceInstaller {
  /// The install as it is now.
  Future<TomSecretsServiceInstallState> state();

  /// Installs (or updates) it from the app's distribution, started at
  /// login; throws [TomSecretsServiceInstallException].
  Future<TomSecretsServiceInstallState> install();

  /// Removes it and its start at login; throws
  /// [TomSecretsServiceInstallException] (on Windows while the installed
  /// service runs: stop it first).
  Future<TomSecretsServiceInstallState> uninstall();
}

/// An install or removal that failed, [message] saying why.
final class TomSecretsServiceInstallException implements Exception {
  /// A failure.
  const TomSecretsServiceInstallException(this.message);

  /// Why, for the user.
  final String message;

  @override
  String toString() => message;
}
