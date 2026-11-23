// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The giving side of a pairing in the app (part-sharing, part-app Pairing
/// screen): the pairing window on this machine's LAN and VPN addresses with
/// its code, the bundle the user chooses once the other device proved the
/// code (the vaults with their keys, the shared configuration, tokens pasted
/// for that device), and what the service keeps afterwards (`pair.record`);
/// the device records (`pair.list`, `pair.revoke`). With a relay chosen
/// (part-relay), the window also waits there under the code's number — the
/// LAN and the VPN first, the relay for a machine that reaches neither —
/// and the QR code names it; a relay that fails is said, never replaced by
/// another silently.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/pairing_discovery.dart';
import 'pairing_invitation.dart';
import 'relay_settings.dart';
import 'service_connection.dart';

/// Where a pairing stands.
enum TomSecretsPairingStage {
  /// No window is open.
  idle,

  /// The window is open and shows the code.
  waiting,

  /// The other device proved the code: the user chooses what it gets.
  choosing,

  /// The bundle is on its way.
  sending,

  /// The pairing ended with the device paired.
  paired,

  /// The pairing ended without it (wrong code, closed, declined, failed).
  failed,
}

/// A vault the bundle may carry, with its keys (from `vaultKeys`).
final class TomSecretsPairingChoice {
  TomSecretsPairingChoice._(this.vault);

  /// The vault and its keys.
  final TomSecretsPairingVault vault;

  /// Whether it goes into the bundle.
  bool chosen = true;

  /// The ids of its keys: the key file's hash, the repository key's id.
  List<String> get keyIds => [
    if (vault.keyFile != null) TomSecretsKeyFile.parse(vault.keyFile!).hash,
    if (vault.repositoryKey != null)
      TomSecretsRepositoryKey.fromBase64(vault.repositoryKey!).keyIdHex,
  ];

  /// Its `github:` repository (`owner/name`), or null.
  String? get repository {
    final parsed = TomSecretsVaultLocator.parse(vault.locator);
    return parsed is TomSecretsGitHubLocator ? parsed.repositorySlug : null;
  }
}

/// The giving side of a pairing, over [connection].
class TomSecretsPairingModel extends ChangeNotifier {
  /// A model over [connection]; [addresses] gives the addresses the window
  /// listens on (default this machine's LAN and VPN addresses), and
  /// [allowLoopback] lets it listen on loopback (tests only).
  TomSecretsPairingModel(
    this.connection, {
    Future<List<InternetAddress>> Function()? addresses,
    this.allowLoopback = false,
    this.window = tomSecretsPairingWindow,
    this.discovery,
    TomSecretsRelay Function(
      TomSecretsRelayId id,
      List<(String, String)> stores,
      String device,
    )?
    relayFor,
  }) : _addresses = addresses ?? tomSecretsPairingAddresses,
       _relayFor =
           relayFor ??
           ((id, stores, device) => tomSecretsAppRelay(
             id,
             connection,
             stores: stores,
             device: device,
           ));

  final TomSecretsRelay Function(
    TomSecretsRelayId id,
    List<(String, String)> stores,
    String device,
  )
  _relayFor;

  /// The relay the next window also waits on (the default relay for
  /// pairing, or the one chosen on the Pairing screen); null: the LAN and
  /// the VPN only.
  TomSecretsRelayId? pairingRelay;

  TomSecretsRelayId? _relay;
  String? _relayFailure;

  /// The relay the open window also waits on, or null.
  TomSecretsRelayId? get relay => _relay;

  /// Why the relay is not used (it could not host, or failed before anyone
  /// came; the window stays open on the LAN), or null.
  String? get relayProblem {
    if (_relayFailure != null) return _relayFailure;
    final error = _window?.relayError;
    if (error == null) return null;
    return error is TomSecretsRelayException
        ? 'The relay ${error.relay} failed: ${error.message}'
        : 'The relay failed: $error';
  }

  /// mDNS for announcing the window on the LAN, or null.
  final TomSecretsPairingDiscovery? discovery;

  TomSecretsPairingAdvertising? _advertising;

  /// Whether the open window is announced on the LAN (`_tsm-pair._tcp`), so
  /// the other machine finds it by the code's number.
  bool get announced => _advertising != null;

  /// The admin connection.
  final TomSecretsServiceConnection connection;

  final Future<List<InternetAddress>> Function() _addresses;

  /// Whether the window may listen on loopback (tests only).
  final bool allowLoopback;

  /// How long the window stays open.
  final Duration window;

  TomSecretsPairingStage _stage = TomSecretsPairingStage.idle;
  TomSecretsPairingWindow? _window;
  TomSecretsPairingCode? _code;
  DateTime? _closesAt;
  Timer? _tick;
  String? _receiver;
  String? _message;
  List<TomSecretsPairingChoice> _choices = const [];
  String? _configYaml;
  bool includeConfig = true;
  final Map<String, String> tokens = {};
  Completer<TomSecretsPairingBundle?>? _decision;
  TomSecretsPairingPeerKeys? _identity;
  List<TomSecretsDeviceRecord> _devices = const [];

  /// Where the pairing stands.
  TomSecretsPairingStage get stage => _stage;

  /// The code the window shows.
  TomSecretsPairingCode? get code => _code;

  /// The addresses and port the window listens on (`address:port`).
  List<String> get listening => [
    if (_window != null)
      for (final a in _window!.addresses)
        a.type == InternetAddressType.IPv6
            ? '[${a.address}]:${_window!.port}'
            : '${a.address}:${_window!.port}',
  ];

  /// The port the window listens on, or null.
  int? get port => _window?.port;

  /// The open window as its QR code tells it (DP-56, part-relay), or null.
  TomSecretsPairingInvitation? get invitation {
    final window = _window;
    final code = _code;
    final relay = window?.relayError == null ? _relay : null;
    if (window == null ||
        code == null ||
        (window.addresses.isEmpty && relay == null)) {
      return null;
    }
    return TomSecretsPairingInvitation(
      addresses: [for (final a in window.addresses) a.address],
      port: window.port,
      code: code,
      relay: relay,
    );
  }

  /// The time left before the window closes.
  Duration get remaining {
    final at = _closesAt;
    if (at == null) return Duration.zero;
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// The receiving device's name, once it proved the code.
  String? get receiver => _receiver;

  /// The last result or failure, for the user.
  String? get message => _message;

  /// The vaults the bundle may carry, the primary first.
  List<TomSecretsPairingChoice> get choices => _choices;

  /// The shared configuration, or null when the primary has none.
  String? get configYaml => _configYaml;

  /// The `github:` repositories of the vaults chosen (a token may be pasted
  /// for each).
  List<String> get repositories => {
    for (final c in _choices)
      if (c.chosen) ?c.repository,
  }.toList()..sort();

  /// The device records.
  List<TomSecretsDeviceRecord> get devices => _devices;

  /// Reads the device records (`pair.list`).
  Future<void> loadDevices() async {
    final answer = await connection.request('pair.list');
    _devices = [
      for (final d in (answer['devices'] as List? ?? const []).cast<Map>())
        _deviceRecord(d.cast<String, Object?>()),
    ];
    notifyListeners();
  }

  static TomSecretsDeviceRecord _deviceRecord(Map<String, Object?> m) {
    DateTime? time(String key) =>
        m[key] is String ? DateTime.tryParse(m[key]! as String)?.toUtc() : null;
    return TomSecretsDeviceRecord(
      device: m['device']! as String,
      platform: m['platform'] as String?,
      paired: time('paired') ?? DateTime.utc(1970),
      pairedBy: m['pairedBy'] as String?,
      keyIds: [for (final k in (m['keyIds'] as List? ?? const [])) '$k'],
      approverKeyId: m['approverKeyId'] as String?,
      approverKeySince: time('approverKeySince'),
      linkKeySince: time('linkKeySince'),
      revoked: time('revoked'),
      githubAuth: TomSecretsGitHubAuth.of(m['githubAuth'] as String?),
      githubTokenExpires: time('githubTokenExpires'),
    );
  }

  /// Revokes [device] (`pair.revoke`) and reads the records again.
  Future<void> revoke(String device) async {
    await connection.request('pair.revoke', {'device': device});
    await loadDevices();
  }

  /// Opens the pairing window: the vaults and their keys read
  /// (`vaultKeys`), this device's keys (`pair.identity`), a fresh code, the
  /// window on the addresses for [window]. Throws when no address can be
  /// listened on.
  Future<void> open() async {
    await close();
    _message = null;
    _receiver = null;
    tokens.clear();
    // A relay server chosen for the pairing is offered for the approval
    // link too (part-relay): the identity names it with a fresh link id.
    final linkRelay = pairingRelay?.kind == TomSecretsRelayKind.server
        ? pairingRelay!.text
        : null;
    final identity = await connection.request('pair.identity', {
      'relay': ?linkRelay,
    });
    _identity = TomSecretsPairingPeerKeys.fromJson(identity);
    final device = identity['device']! as String;
    await _readChoices();
    final addresses = await _addresses();
    _relay = null;
    _relayFailure = null;
    TomSecretsPairingChannel? channel;
    final chosen = pairingRelay;
    if (chosen != null) {
      try {
        channel = await _relayFor(chosen, [
          for (final c in _choices) (c.vault.name, c.vault.locator),
        ], device).host();
        _relay = chosen;
      } on TomSecretsRelayException catch (e) {
        _relayFailure = 'The relay ${e.relay} cannot host: ${e.message}';
      }
    }
    if (addresses.isEmpty && channel == null) {
      _fail(
        _relayFailure == null
            ? 'This machine has no LAN or VPN address to listen on.'
            : '${_relayFailure!}; and this machine has no LAN or VPN address '
                  'to listen on.',
      );
      return;
    }
    final random = TomSecretsPairingCode.generate();
    final code = _code = channel == null
        ? random
        : TomSecretsPairingCode(int.parse(channel.nameplate), random.words);
    final TomSecretsPairingWindow opened;
    try {
      opened = _window = await TomSecretsPairingWindow.open(
        addresses: addresses,
        allowLoopback: allowLoopback,
        code: code,
        device: device,
        bundleFor: _bundleFor,
        window: window,
        relayChannel: channel,
      );
    } on Object {
      await channel?.close();
      rethrow;
    }
    _closesAt = DateTime.now().add(window);
    _stage = TomSecretsPairingStage.waiting;
    await _announce(opened, device, code);
    _tick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();
    unawaited(_await(opened));
  }

  Future<void> _announce(
    TomSecretsPairingWindow opened,
    String device,
    TomSecretsPairingCode code,
  ) async {
    final d = discovery;
    if (d == null || opened.addresses.isEmpty) return;
    try {
      final advertising = await d.advertise(
        TomSecretsPairingAdvert(
          device: device,
          number: code.number,
          port: opened.port,
          addresses: [for (final a in opened.addresses) a.address],
        ),
      );
      if (_window == opened) {
        _advertising = advertising;
      } else {
        await advertising.stop();
      }
    } on Object {
      // Not announced: the other machine types the address shown.
    }
  }

  Future<void> _readChoices() async {
    final set = await connection.request('vaultKeys');
    final unserved = [
      for (final u in (set['unserved'] as List? ?? const []).cast<Map>())
        u['store'] as String,
    ];
    final all = unserved.isEmpty
        ? set
        : await connection.request('vaultKeys', {
            'stores': [
              for (final s in (set['stores'] as List).cast<Map>())
                s['store'] as String,
              ...unserved,
            ],
          });
    final stores = (all['stores'] as List? ?? const []).cast<Map>();
    final choices = <TomSecretsPairingChoice>[];
    for (final (i, s) in stores.indexed) {
      final keys = (s['keys'] as Map? ?? const {}).cast<String, Object?>();
      final keyFile = keys['keyFile'] as String?;
      choices.add(
        TomSecretsPairingChoice._(
          TomSecretsPairingVault(
            name: s['store'] as String,
            locator: s['location'] as String,
            primary: i == 0,
            keyFile: keyFile == null ? null : base64.decode(keyFile),
            repositoryKey: keys['outerKey'] as String?,
          ),
        ),
      );
    }
    _choices = choices;
  }

  /// The shared configuration the bundle may carry; set by the screen from
  /// the session (the primary's `tsm.config`, BP-43).
  set configYaml(String? yaml) {
    _configYaml = yaml;
    notifyListeners();
  }

  Future<TomSecretsPairingBundle?> _bundleFor(String receiver) {
    _receiver = receiver;
    _stage = TomSecretsPairingStage.choosing;
    final decision = _decision = Completer();
    notifyListeners();
    return decision.future;
  }

  /// Ticks or unticks [choice].
  void toggle(TomSecretsPairingChoice choice, bool chosen) {
    choice.chosen = chosen;
    notifyListeners();
  }

  /// Sends the bundle the user chose.
  void confirm() {
    final decision = _decision;
    final identity = _identity;
    if (decision == null || decision.isCompleted || identity == null) return;
    _stage = TomSecretsPairingStage.sending;
    notifyListeners();
    decision.complete(
      TomSecretsPairingBundle(
        vaults: [
          for (final c in _choices)
            if (c.chosen) c.vault,
        ],
        giverKeys: identity,
        configYaml: includeConfig ? _configYaml : null,
        tokens: [
          for (final r in repositories)
            if ((tokens[r] ?? '').trim().isNotEmpty)
              TomSecretsPairingToken(repository: r, token: tokens[r]!.trim()),
        ],
      ),
    );
  }

  /// Declines the device: nothing is sent.
  void decline() {
    final decision = _decision;
    if (decision == null || decision.isCompleted) return;
    decision.complete(null);
  }

  Future<void> _await(TomSecretsPairingWindow opened) async {
    try {
      final given = await opened.result;
      if (_window != opened) return;
      try {
        await _record(given);
      } on Object catch (e) {
        _fail('The device paired, but the service did not keep it: $e');
      }
    } on TomSecretsPairingException catch (e) {
      if (_window != opened) return;
      _fail(switch (e.failure) {
        TomSecretsPairingFailure.wrongCode =>
          'Wrong code: the pairing is closed. Open a new one.',
        TomSecretsPairingFailure.declined => 'Declined: nothing was sent.',
        TomSecretsPairingFailure.closed =>
          'The pairing window closed without a device.',
        TomSecretsPairingFailure.refused => 'Not paired: ${e.message}.',
        _ => 'The pairing failed: ${e.message}',
      });
    } on TomSecretsRelayException catch (e) {
      if (_window != opened) return;
      _fail(
        'The relay ${e.relay} failed: ${e.message}. Open a new pairing, on '
        'another relay or on the same network.',
      );
    } finally {
      if (_window == opened) await _stop();
    }
  }

  Future<void> _record(TomSecretsPairingGiven given) async {
    final keys = given.receiverKeys;
    final keyIds = [
      for (final c in _choices)
        if (c.chosen) ...c.keyIds,
    ];
    await connection.request('pair.record', {
      'device': given.receiver,
      'tokenKey': base64.encode(given.tokenKey),
      'host': {'linkKey': keys.linkKey.toJson(), 'address': ?keys.linkAddress},
      if (keys.approverKey != null)
        'approver': {
          'approverKey': keys.approverKey!.toJson(),
          'linkKey': keys.linkKey.toJson(),
        },
      'record': {'keyIds': keyIds},
      // The relay link both sides agreed on (part-relay).
      if (_identity != null)
        if (tomSecretsPairingLink(_identity!, keys) case final link?)
          'link': {'relay': link.relay, 'linkId': link.linkId},
    });
    _stage = TomSecretsPairingStage.paired;
    _message =
        '${given.receiver} is paired: it received '
        '${_choices.where((c) => c.chosen).length} vault(s)'
        '${keys.approverKey != null ? ' and approves for this machine' : ''}.';
    notifyListeners();
    await loadDevices();
  }

  void _fail(String message) {
    _stage = TomSecretsPairingStage.failed;
    _message = message;
    notifyListeners();
  }

  Future<void> _stop() async {
    final advertising = _advertising;
    _advertising = null;
    try {
      await advertising?.stop();
    } on Object {
      // The announcement ends with the window anyway.
    }
    _tick?.cancel();
    _tick = null;
    _closesAt = null;
    final w = _window;
    _window = null;
    await w?.close();
    notifyListeners();
  }

  /// Closes the window; a pairing waiting for the user's choice is declined
  /// (the app locked, or the user left).
  Future<void> close() async {
    decline();
    if (_stage == TomSecretsPairingStage.waiting ||
        _stage == TomSecretsPairingStage.choosing) {
      _stage = TomSecretsPairingStage.idle;
    }
    await _stop();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    _disposed = true;
    super.dispose();
  }
}
