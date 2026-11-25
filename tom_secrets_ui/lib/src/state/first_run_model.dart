// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The First run wizard's state (part-app, Screens › First run): the choices
/// of its steps, which step may go on, and the setup they make, run through
/// `tom_secrets_core`'s [TomSecretsFirstRun], then the service started and
/// unlocked.
library;

import 'dart:io' show InternetAddress, Platform;

import 'package:flutter/foundation.dart';
import 'package:tom_core_storage/tom_core_storage.dart'
    show
        TomToken,
        TomTokenListing,
        TomTokenRejectedException,
        TomTokenRequiredException;
import 'package:tom_credentials_ui/tom_credentials_ui.dart'
    show TomKeyFile, TomTokenKeeper;
import 'package:tom_secrets_client/admin.dart'
    show TomSecretsAdminException, tomSecretsApprovalLinkProblem;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/pairing_discovery.dart';
import 'emergency_sheet.dart';

import 'service_connection.dart';

/// The wizard's steps.
enum TomSecretsFirstRunStep {
  /// 1. The primary vault: created or opened, local or on GitHub, the master
  /// password.
  primary,

  /// 2. The protection layers.
  protection,

  /// 3. This machine's settings.
  machine,

  /// 4. Done: what to do next.
  done,
}

/// How the service relocks, as the wizard offers it.
enum TomSecretsFirstRunLock {
  /// Never on its own.
  never,

  /// After an idle period.
  idle,
}

/// The host GitHub tokens are for.
const String tomSecretsGitHubHost = 'github.com';

/// The shortest master password a new primary takes.
const int tomSecretsMinimumPasswordLength = 10;

/// The wizard's state; also the token keeper of its token prompt.
class TomSecretsFirstRunModel extends ChangeNotifier implements TomTokenKeeper {
  /// The state of a wizard writing through [firstRun] and starting the
  /// service through [connection].
  TomSecretsFirstRunModel({
    required this.firstRun,
    required this.connection,
    this.discovery,
    Future<List<InternetAddress>> Function()? ownAddresses,
    TomSecretsRelay Function(TomSecretsRelayId id, String? token, String host)?
    relayFor,
  }) : _ownAddresses = ownAddresses ?? tomSecretsPairingAddresses,
       _relayFor =
           relayFor ??
           ((id, token, host) =>
               tomSecretsRelayFor(id, token: token, device: host)),
       localPath = _join(
         _join(firstRun.dataDirectory, 'vaults'),
         'primary.kdbx',
       ),
       host = tomSecretsDefaultHost();

  /// Where the first run writes.
  final TomSecretsFirstRun firstRun;

  /// The service connection, to start and unlock the service at the end.
  final TomSecretsServiceConnection connection;

  /// mDNS for finding the other machine's pairing window by the code's
  /// number, or null (the address is typed).
  final TomSecretsPairingDiscovery? discovery;

  final Future<List<InternetAddress>> Function() _ownAddresses;

  /// The relay a pairing goes through (part-relay): a relay server, or
  /// GitHub reached with this machine's own token.
  final TomSecretsRelay Function(
    TomSecretsRelayId id,
    String? token,
    String host,
  )
  _relayFor;

  /// The relay server the approval link may also go through: the one the
  /// pairing names, when it is a relay server (part-relay).
  static String? _linkRelay(TomSecretsRelayId? relay) =>
      relay?.kind == TomSecretsRelayKind.server ? relay!.text : null;

  static String _join(String a, String b) =>
      '$a${Platform.isWindows ? r'\' : '/'}$b';

  TomSecretsFirstRunStep _step = TomSecretsFirstRunStep.primary;

  /// The step shown.
  TomSecretsFirstRunStep get step => _step;

  // ---- Step 1 ----

  bool _byPairing = false;

  /// Whether the machine is set up by pairing with another desktop (the
  /// protection step is left out: the keys come with the pairing).
  bool get byPairing => _byPairing;
  set byPairing(bool value) => _update(() {
    _byPairing = value;
    _receipt = null;
  });

  /// The giving machine's address as its Pairing screen shows it
  /// (`host:port`); empty: found on the LAN by the code's number.
  String pairAddress = '';

  /// Whether the other machine can be found on the LAN by the code alone.
  bool get canFind => discovery != null;

  /// The code its Pairing screen shows.
  String pairCode = '';

  /// The relay its Pairing screen names (`tsm:<url>` or
  /// `github:<owner>/<repo>`), when it pairs through one too; empty: none
  /// (part-relay). Tried after the address, or alone when no address is
  /// given.
  String pairRelay = '';

  /// This machine's own GitHub token for a GitHub relay's repository (a
  /// pairing through GitHub needs the repository reachable before it
  /// starts); it also opens the primary when that is in the repository. A
  /// relay server needs none.
  String pairRelayToken = '';

  String? _pairedThrough;

  /// How the pairing went: the address, or the relay's id.
  String? get pairedThrough => _pairedThrough;

  /// Where this machine's approval link listens (`address:port`, the
  /// device setting `approvalLink`); empty: no link. The giving machine is
  /// told it with the pairing, so its service opens the link.
  String pairLink = '';

  TomSecretsPairingReceipt? _receipt;

  /// The pairing received (held in memory until the setup), or null.
  TomSecretsPairingReceipt? get receipt => _receipt;

  bool _receiving = false;

  /// Whether a pairing is being received.
  bool get receiving => _receiving;

  /// Receives the pairing from [pairAddress] with [pairCode] as [host]:
  /// nothing is stored until [setUp]. A failure is shown as the error.
  Future<void> receive() async {
    if (_receiving) return;
    final TomSecretsPairingCode code;
    try {
      code = TomSecretsPairingCode.parse(pairCode);
    } on FormatException catch (e) {
      fail(e.message);
      return;
    }
    final link = _pairLink;
    final linkProblem = link == null
        ? null
        : tomSecretsApprovalLinkProblem(link);
    if (linkProblem != null) {
      fail(linkProblem);
      return;
    }
    TomSecretsRelayId? relayId;
    if (pairRelay.trim().isNotEmpty) {
      try {
        relayId = TomSecretsRelayId.parse(pairRelay);
      } on FormatException catch (e) {
        fail(e.message);
        return;
      }
      if (tomSecretsRelayNeedsToken(relayId) && pairRelayToken.trim().isEmpty) {
        fail(
          'A pairing through GitHub needs this machine to reach '
          '${relayId.address} first: paste a token for it (contents read and '
          'write).',
        );
        return;
      }
    }
    _update(() {
      _receiving = true;
      _receipt = null;
      _pairedThrough = null;
    });
    try {
      if (pairAddress.trim().isNotEmpty || relayId == null) {
        final (String, int)? at;
        try {
          at = pairAddress.trim().isEmpty
              ? await _find(code.number)
              : tomSecretsParsePairingAddress(pairAddress);
        } on FormatException catch (e) {
          fail(e.message);
          return;
        }
        if (at == null) return;
        try {
          final receipt = await tomSecretsReceivePairingForSetup(
            address: at.$1,
            port: at.$2,
            code: code,
            device: host,
            linkAddress: link,
            linkRelay: _linkRelay(relayId),
          );
          _update(() {
            _receipt = receipt;
            _pairedThrough = pairAddress.trim();
          });
          return;
        } on TomSecretsPairingException catch (e) {
          // Not reachable on the LAN or the VPN: the relay next, when the
          // other machine named one (part-relay: the LAN first).
          if (relayId == null || e.failure != TomSecretsPairingFailure.closed) {
            rethrow;
          }
        }
      }
      final token = pairRelayToken.trim();
      final needsToken = tomSecretsRelayNeedsToken(relayId);
      final receipt = await tomSecretsReceivePairingForSetup(
        relay: _relayFor(relayId, needsToken ? token : null, host),
        ownTokens: needsToken ? {relayId.address: token} : const {},
        code: code,
        device: host,
        linkAddress: link,
        linkRelay: _linkRelay(relayId),
      );
      _update(() {
        _receipt = receipt;
        _pairedThrough = relayId!.text;
      });
    } on TomSecretsRelayException catch (e) {
      fail(
        'The relay ${e.relay} failed: ${e.message}. Pair on the same network '
        'or over the VPN, or open a pairing on another relay there.',
      );
    } on TomSecretsPairingException catch (e) {
      fail(switch (e.failure) {
        TomSecretsPairingFailure.wrongCode =>
          'Wrong code: the other machine closed its pairing window. Open a '
              'new one there and type its new code.',
        TomSecretsPairingFailure.declined =>
          'The other machine declined: nothing was received.',
        TomSecretsPairingFailure.refused => 'Not set up: ${e.message}.',
        _ => 'The pairing failed: ${e.message}',
      });
    } finally {
      _receiving = false;
      notifyListeners();
    }
  }

  /// The window with [number] found on the LAN, or null (told).
  Future<(String, int)?> _find(int number) async {
    final d = discovery;
    if (d == null) {
      fail('Type the other machine\'s address as its Pairing screen shows it.');
      return null;
    }
    final found = await tomSecretsFindPairingWindow(
      d,
      number,
      await _ownAddresses(),
    );
    if (found.problem != null) {
      fail(found.problem!);
      return null;
    }
    pairAddress = found.typed!;
    return (found.address!, found.port!);
  }

  bool _create = true;

  /// Whether a new primary is created (else one is opened).
  bool get create => _create;
  set create(bool value) => _update(() => _create = value);

  bool _onGitHub = false;

  /// Whether the primary is in a GitHub repository (else on this computer).
  bool get onGitHub => _onGitHub;
  set onGitHub(bool value) => _update(() => _onGitHub = value);

  /// The local file (a new primary gets `.tsmx` appended when it is outer
  /// encrypted).
  String localPath;

  /// The repository's owner.
  String owner = '';

  /// The repository's name.
  String repository = '';

  /// The file's path in the repository.
  String repositoryPath = 'primary.kdbx';

  String? _token;

  /// Whether a GitHub token was entered.
  bool get hasToken => _token != null;

  /// The token's expiry: as GitHub reported it at the check, or entered.
  DateTime? tokenExpires;

  TomSecretsGitHubRepositoryCheck? _checked;

  /// The repository check that passed for the current owner, repository
  /// and token, or null.
  TomSecretsGitHubRepositoryCheck? get checked => _checked;

  /// The master password typed.
  String password = '';

  /// The master password typed again (a new primary).
  String repeat = '';

  /// The key file chosen to open an existing primary with.
  TomKeyFile? openKeyFile;

  // ---- Step 2 ----

  Uint8List? _newKeyFile;

  /// Whether a new primary gets a key file.
  bool get useKeyFile => _newKeyFile != null;
  set useKeyFile(bool value) => _update(() {
    _newKeyFile = value ? TomSecretsKeyFile.generate().toBytes() : null;
    keyFileSaved = false;
  });

  /// The new key file's bytes (a KeePass 2.0 XML key file), or null.
  Uint8List? get newKeyFile => _newKeyFile;

  /// Whether a copy of the new key file was saved.
  bool keyFileSaved = false;

  TomSecretsRepositoryKey? _newRepositoryKey;

  /// Whether a new primary is outer encrypted.
  bool get useOuter => _newRepositoryKey != null;
  set useOuter(bool value) => _update(() {
    _newRepositoryKey = value ? TomSecretsRepositoryKey.generate() : null;
    repositoryKeySaved = false;
  });

  /// The new repository key, or null.
  TomSecretsRepositoryKey? get newRepositoryKey => _newRepositoryKey;

  /// Whether a copy of the new repository key was saved.
  bool repositoryKeySaved = false;

  /// The outer cipher of a new primary.
  TomSecretsOuterCipher cipher = TomSecretsOuterCipher.xchacha20Poly1305;

  /// The repository key typed (base64) to open an outer-encrypted primary.
  String openRepositoryKey = '';

  // ---- Step 3 ----

  /// This machine's host name.
  String host;

  /// The machine's default environment, or empty for none.
  String defaultEnvironment = '';

  /// Whether this machine serves only the primary (else every vault it
  /// lists).
  bool servesPrimaryOnly = false;

  /// How the service relocks.
  TomSecretsFirstRunLock lock = TomSecretsFirstRunLock.idle;

  /// The idle period in minutes.
  int idleMinutes = 30;

  /// Where the device settings container's key is kept.
  TomSecretsDeviceKeyMode deviceKey = TomSecretsDeviceKeyMode.auto;

  // ---- Running ----

  bool _busy = false;

  /// Whether the setup, the start or the unlock runs.
  bool get busy => _busy;

  String? _error;

  /// What went wrong last, for the user.
  String? get error => _error;

  TomSecretsFirstRunResult? _result;

  /// What the first run did, once it succeeded.
  TomSecretsFirstRunResult? get result => _result;

  void _update(void Function() change) {
    change();
    _error = null;
    notifyListeners();
  }

  /// Marks a field changed: the wizard rebuilds, a stale error goes.
  void changed() => _update(() {});

  /// The file name of the primary, as it will be written or read.
  String get fileName {
    final raw = _onGitHub ? repositoryPath.trim() : localPath.trim();
    final name = raw.split(RegExp(r'[/\\]')).last;
    return _create && useOuter && !name.endsWith(tomSecretsOuterSuffix)
        ? '$name$tomSecretsOuterSuffix'
        : name;
  }

  /// Whether the primary to open is outer encrypted.
  bool get openIsOuter => !_create && fileName.endsWith(tomSecretsOuterSuffix);

  /// The primary's locator; null while the fields cannot make one.
  TomSecretsVaultLocator? get locator {
    try {
      if (_onGitHub) {
        final path = repositoryPath.trim();
        if (owner.trim().isEmpty || repository.trim().isEmpty || path.isEmpty) {
          return null;
        }
        final full =
            _create && useOuter && !path.endsWith(tomSecretsOuterSuffix)
            ? '$path$tomSecretsOuterSuffix'
            : path;
        return TomSecretsVaultLocator.parse(
          'github:${owner.trim()}/${repository.trim()}/$full',
        );
      }
      final path = localPath.trim();
      if (path.isEmpty) return null;
      final full = _create && useOuter && !path.endsWith(tomSecretsOuterSuffix)
          ? '$path$tomSecretsOuterSuffix'
          : path;
      return TomSecretsVaultLocator.parse('file:$full');
    } on TomSecretsLocatorException {
      return null;
    }
  }

  /// What keeps the current step from going on, or null when it may.
  String? get blocker {
    switch (_step) {
      case TomSecretsFirstRunStep.primary when _byPairing:
        if (_receipt == null) {
          return 'Receive the pairing from the other machine.';
        }
        if (password.isEmpty) return 'Type the master password.';
        return null;
      case TomSecretsFirstRunStep.primary:
        if (locator == null) {
          return _onGitHub
              ? 'Name the repository\'s owner, the repository and the file.'
              : 'Give the vault file\'s full path.';
        }
        if (_onGitHub && _checked == null) {
          return 'Check the repository with your token.';
        }
        if (_create) {
          if (password.length < tomSecretsMinimumPasswordLength) {
            return 'The master password needs at least '
                '$tomSecretsMinimumPasswordLength characters.';
          }
          if (password != repeat) return 'The two passwords differ.';
        } else if (password.isEmpty) {
          return 'Type the master password.';
        }
        return null;
      case TomSecretsFirstRunStep.protection:
        if (openIsOuter) {
          try {
            TomSecretsRepositoryKey.fromBase64(openRepositoryKey.trim());
          } on Object {
            return 'Give the repository key: 44 characters of base64.';
          }
        }
        return null;
      case TomSecretsFirstRunStep.machine:
        if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(host)) {
          return 'The host name is lower-case letters, digits and "-".';
        }
        if (lock == TomSecretsFirstRunLock.idle && idleMinutes < 1) {
          return 'The idle period is at least one minute.';
        }
        return null;
      case TomSecretsFirstRunStep.done:
        return null;
    }
  }

  /// Goes to the next step (the machine step's next is [setUp]).
  void next() {
    if (blocker != null ||
        _step.index >= TomSecretsFirstRunStep.machine.index) {
      return;
    }
    _update(
      () => _step = _byPairing && _step == TomSecretsFirstRunStep.primary
          ? TomSecretsFirstRunStep.machine
          : TomSecretsFirstRunStep.values[_step.index + 1],
    );
  }

  /// Goes back a step (not from the last: the machine is set up then).
  void back() {
    if (_step == TomSecretsFirstRunStep.primary ||
        _step == TomSecretsFirstRunStep.done) {
      return;
    }
    _update(
      () => _step = _byPairing && _step == TomSecretsFirstRunStep.machine
          ? TomSecretsFirstRunStep.primary
          : TomSecretsFirstRunStep.values[_step.index - 1],
    );
  }

  /// The primary's locator as set up: the one chosen, or the one the
  /// pairing gave.
  String? get primaryLocatorText =>
      _byPairing ? _receipt?.primary.locator : locator?.text;

  // ---- The GitHub token (TomTokenKeeper) ----

  @override
  bool get keepsBeyondSession => false;

  @override
  Future<List<TomTokenListing>> listTokens() async => const [];

  @override
  Future<bool> storeToken(TomToken token) async {
    _update(() {
      _token = token.secret.trim();
      _checked = null;
      tokenExpires = null;
    });
    return false;
  }

  @override
  Future<bool> revokeToken(String host) async {
    _update(() {
      _token = null;
      _checked = null;
    });
    return false;
  }

  /// Forgets a passed check: the owner or the repository changed.
  void repositoryChanged() => _update(() => _checked = null);

  /// Checks the repository with the token: throws
  /// [TomTokenRequiredException] without one and [TomTokenRejectedException]
  /// when GitHub refuses it (the token prompt answers both), a
  /// [TomSecretsFirstRunException] for anything else.
  Future<TomSecretsGitHubRepositoryCheck> checkGitHub() async {
    final token = _token;
    if (token == null) {
      throw const TomTokenRequiredException(tomSecretsGitHubHost);
    }
    try {
      final check = await firstRun.checkGitHub(
        owner: owner.trim(),
        repository: repository.trim(),
        token: token,
      );
      _update(() {
        _checked = check;
        tokenExpires = check.expires ?? tokenExpires;
      });
      return check;
    } on TomSecretsFirstRunException catch (e) {
      if (e.problem == TomSecretsFirstRunProblem.tokenRefused) {
        throw TomTokenRejectedException(
          'github:${owner.trim()}/${repository.trim()}',
          tomSecretsGitHubHost,
          e.message,
        );
      }
      rethrow;
    }
  }

  /// Shows [message] as the wizard's error.
  void fail(String message) {
    _error = message;
    notifyListeners();
  }

  /// The emergency sheet of the primary being created (BP-37): its
  /// locator, the new key file and repository key, the outer cipher; the
  /// master password is never put on it.
  TomSecretsEmergencySheet get emergencySheet => TomSecretsEmergencySheet.of(
    primaryName: 'primary',
    primaryLocator: locator!.text,
    primaryKeyFile: _newKeyFile,
    primaryOuterKey: _newRepositoryKey?.toBase64(),
    primaryCipher: useOuter ? cipher : null,
  );

  /// The setup the choices make.
  TomSecretsFirstRunSetup get setup => TomSecretsFirstRunSetup(
    primary: locator!,
    create: _create,
    masterPassword: password,
    keyFile: _create ? _newKeyFile : openKeyFile?.bytes,
    repositoryKey: _create
        ? _newRepositoryKey
        : openIsOuter
        ? TomSecretsRepositoryKey.fromBase64(openRepositoryKey.trim())
        : null,
    cipher: cipher,
    githubToken: _onGitHub ? _token : null,
    githubTokenExpires: _onGitHub ? tokenExpires : null,
    settings: settings,
    deviceKey: deviceKey,
    host: host == tomSecretsDefaultHost() ? null : host,
  );

  String? get _pairLink => pairLink.trim().isEmpty ? null : pairLink.trim();

  /// This machine's settings as step 3 has them (and, set up by pairing,
  /// the approval link given then).
  TomSecretsDeviceSettings get settings => TomSecretsDeviceSettings(
    approvalLink: _byPairing ? _pairLink : null,
    defaultEnvironment: defaultEnvironment.trim().isEmpty
        ? null
        : defaultEnvironment.trim(),
    servedStores: servesPrimaryOnly ? const ['primary'] : null,
    serviceLock: TomSecretsLockPolicy(
      mode: lock == TomSecretsFirstRunLock.never
          ? TomSecretsLockMode.never
          : TomSecretsLockMode.idle,
      idle: Duration(minutes: idleMinutes),
    ),
  );

  /// Sets the machine up, starts the service, attaches and unlocks it with
  /// the master password (the keys come from the keychain), then shows the
  /// last step. A refusal of the setup goes back to the step it is about.
  Future<void> setUp() async {
    if (blocker != null || _busy) return;
    _update(() => _busy = true);
    try {
      final receipt = _receipt;
      _result = _byPairing && receipt != null
          ? await firstRun.runPaired(
              receipt,
              masterPassword: password,
              settings: settings,
              deviceKey: deviceKey,
            )
          : await firstRun.run(setup);
    } on TomSecretsFirstRunException catch (e) {
      _busy = false;
      _step = switch (e.problem) {
        TomSecretsFirstRunProblem.repositoryKeyNeeded ||
        TomSecretsFirstRunProblem.repositoryKeyWrong ||
        TomSecretsFirstRunProblem.inconsistent =>
          TomSecretsFirstRunStep.protection,
        TomSecretsFirstRunProblem.keychainNeeded ||
        TomSecretsFirstRunProblem.alreadySetUp ||
        TomSecretsFirstRunProblem.dataDirectory =>
          TomSecretsFirstRunStep.machine,
        _ => TomSecretsFirstRunStep.primary,
      };
      _error = e.message;
      notifyListeners();
      return;
    }
    await connection.startService();
    if (connection.phase != TomSecretsConnectionPhase.attached) {
      _busy = false;
      _step = TomSecretsFirstRunStep.done;
      _error =
          'The machine is set up, but the service did not start: '
          '${connection.message ?? connection.phase.name}.';
      notifyListeners();
      return;
    }
    try {
      if (connection.locked) {
        await connection.unlock(
          password,
          // The key file chosen to open the primary was kept in the
          // keychain; the service takes it from there.
        );
      }
    } on TomSecretsAdminException catch (e) {
      _error =
          'The machine is set up and the service runs, but it did not '
          'unlock: ${e.message}. Unlock it from the next screen.';
    }
    _busy = false;
    _step = TomSecretsFirstRunStep.done;
    password = '';
    repeat = '';
    notifyListeners();
  }
}
