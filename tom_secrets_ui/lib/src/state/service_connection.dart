// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// `ServiceConnection` of part-app's State: the admin connection to the
/// secrets service, its event stream and what the app knows of the service
/// (locked or not, the stores' states, waiting approvals, keys due).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../ports/service_host.dart';

/// Where the connection stands.
enum TomSecretsConnectionPhase {
  /// Attaching.
  connecting,

  /// No service runs; the app offers to start it.
  noService,

  /// This machine is not set up; the app opens the First run wizard.
  notSetUp,

  /// Starting the service.
  starting,

  /// The service cannot be started (no bootstrap, no executable).
  cannotStart,

  /// Starting it failed.
  startFailed,

  /// A service runs that only a claim attaches to (DP-16).
  claimNeeded,

  /// Attached and subscribed.
  attached,

  /// The connection dropped: the service stopped or died.
  dropped,
}

/// One store as the service reports it (`statusReport.stores`,
/// `store_state`).
@immutable
final class TomSecretsStoreState {
  /// A store [name] in [state] read from [source].
  const TomSecretsStoreState({
    required this.name,
    required this.state,
    this.source,
    this.fetchedAt,
    this.notPushed = 0,
  });

  /// Read from a `statusReport` store or a `store_state` event.
  factory TomSecretsStoreState.fromWire(Map<String, Object?> m) {
    final fetched = m['fetchedAt'];
    return TomSecretsStoreState(
      name: m['name'] as String? ?? m['store'] as String? ?? '',
      state: m['state'] as String? ?? 'unavailable',
      source: m['source'] as String?,
      fetchedAt: fetched is String ? DateTime.tryParse(fetched) : null,
      notPushed: m['notPushed'] is int ? m['notPushed']! as int : 0,
    );
  }

  /// The store's name.
  final String name;

  /// `current`, `offline`, `token_expired`, `needs_unlock` or `unavailable`.
  final String state;

  /// `github`, `file` or `cache`.
  final String? source;

  /// When it was last fetched.
  final DateTime? fetchedAt;

  /// Its changes not yet written to GitHub.
  final int notPushed;

  /// Whether it is served from its offline copy.
  bool get isOffline =>
      state == 'offline' || state == 'token_expired' || source == 'cache';

  /// Why it is offline, for the user, or null.
  String? get offlineReason => switch (state) {
    'token_expired' => 'the GitHub token expired',
    'offline' => 'GitHub is not reachable',
    _ => source == 'cache' ? 'served from the offline copy' : null,
  };
}

/// The admin connection and the service's state.
class TomSecretsServiceConnection extends ChangeNotifier {
  /// A connection through [host]; [connect] attaches.
  TomSecretsServiceConnection(this.host);

  /// The host that starts and attaches.
  final TomSecretsServiceHost host;

  TomSecretsConnectionPhase _phase = TomSecretsConnectionPhase.connecting;
  TomSecretsAdminChannel? _channel;
  StreamSubscription<Map<String, Object?>>? _subscription;
  final StreamController<Map<String, Object?>> _events =
      StreamController.broadcast();
  bool _locked = true;
  String? _message;
  String? _lockMode;
  final Map<String, TomSecretsStoreState> _stores = {};
  final Set<String> _approvals = {};
  final Map<String, Map<String, Object?>> _expiring = {};
  Map<String, Object?> _report = const {};
  bool _unlockNeeded = false;
  bool _disposed = false;

  /// Where the connection stands.
  TomSecretsConnectionPhase get phase => _phase;

  /// Whether the service is locked (true until it says otherwise).
  bool get locked => _locked;

  /// What the last failure was, for the user, or null.
  String? get message => _message;

  /// The service's lock mode (`a`, `b`, `c`), when known.
  String? get lockMode => _lockMode;

  /// The last `statusReport` (the Status view).
  Map<String, Object?> get report => _report;

  /// The stores, by name, as the service reports them.
  Map<String, TomSecretsStoreState> get stores => Map.unmodifiable(_stores);

  /// The approvals waiting for an answer (their ids).
  int get pendingApprovals => _approvals.length;

  /// The keys due a reminder, by key (`statusReport.expiring`, `key_expiry`).
  Map<String, Map<String, Object?>> get expiringKeys =>
      Map.unmodifiable(_expiring);

  /// Whether a client waits for an unlock.
  bool get unlockNeeded => _unlockNeeded;

  /// Whether something needs the user: an unlock or approval waiting, a key
  /// due.
  bool get needsAttention =>
      _unlockNeeded || _approvals.isNotEmpty || _expiring.isNotEmpty;

  /// The service's events, after the connection's own handling.
  Stream<Map<String, Object?>> get events => _events.stream;

  /// Attaches to the service.
  Future<void> connect() async {
    _set(TomSecretsConnectionPhase.connecting);
    await _take(await _guard(host.attach));
  }

  bool _firstRunOpen = false;

  /// Whether the First run wizard is shown: from the moment the machine was
  /// found not set up until the wizard ends ([endFirstRun]), the service
  /// started and attached in between included.
  bool get firstRunOpen => _firstRunOpen;

  /// Ends the First run wizard: the app goes on to the screen of the phase.
  void endFirstRun() {
    _firstRunOpen = false;
    notifyListeners();
  }

  /// Starts the service and attaches.
  Future<void> startService() async {
    _set(TomSecretsConnectionPhase.starting);
    await _take(await _guard(host.start));
  }

  /// Claims the running service with the master [password] (and
  /// [keyFile]). Throws `TomSecretsAdminException` for a wrong password.
  Future<void> claim(String password, {Uint8List? keyFile}) async =>
      _take(await host.claim(password, keyFile: keyFile));

  /// Unlocks with the master [password] (and [keyFile]). Throws
  /// `TomSecretsAdminException` (`denied`, reason `bad_password`).
  Future<void> unlock(String password, {Uint8List? keyFile}) async {
    await request('unlock', {
      'password': password,
      if (keyFile != null) 'keyFile': base64Of(keyFile),
    });
    _locked = false;
    _unlockNeeded = false;
    notifyListeners();
    await refreshStatus();
  }

  /// Opens [store], a file with a password of its own (BP-8).
  Future<void> unlockStore(
    String store,
    String password, {
    Uint8List? keyFile,
  }) async {
    await request('unlockStore', {
      'store': store,
      'password': password,
      if (keyFile != null) 'keyFile': base64Of(keyFile),
    });
    await refreshStatus();
  }

  /// Locks the service: every secret leaves its memory.
  Future<void> lock() async {
    await request('lock');
    _setLocked(true);
  }

  /// Stops the service (locks first); a separate command from quitting the
  /// app (BP-14).
  Future<void> stopService() async {
    await request('shutdown');
  }

  /// Fetches every store now.
  Future<void> reload() => request('reload');

  /// Reads `status` again.
  Future<void> refreshStatus() async {
    final report = await request('status');
    _report = report;
    _locked = report['locked'] == true;
    _lockMode = report['lockMode'] as String?;
    _stores
      ..clear()
      ..addEntries([
        for (final s in (report['stores'] as List? ?? const []).cast<Map>())
          MapEntry(
            s['name'] as String,
            TomSecretsStoreState.fromWire(s.cast<String, Object?>()),
          ),
      ]);
    _expiring
      ..clear()
      ..addEntries([
        for (final k in (report['expiring'] as List? ?? const []).cast<Map>())
          MapEntry(k['key'] as String, k.cast<String, Object?>()),
      ]);
    notifyListeners();
  }

  /// Sends [op] over the attached connection. Throws
  /// `TomSecretsAdminException`, kind `not_running` while not attached.
  Future<Map<String, Object?>> request(
    String op, [
    Map<String, Object?> args = const {},
  ]) {
    final channel = _channel;
    if (channel == null || _phase != TomSecretsConnectionPhase.attached) {
      return Future.error(
        TomSecretsAdminException('not_running', 'not attached to the service'),
      );
    }
    return channel.request(op, args);
  }

  Future<TomSecretsAttach> _guard(Future<TomSecretsAttach> Function() f) async {
    try {
      return await f();
    } on TomSecretsAdminException catch (e) {
      return e.kind == 'not_running'
          ? const TomSecretsNoService()
          : TomSecretsServiceStartFailed(e.message);
    }
  }

  Future<void> _take(TomSecretsAttach result) async {
    switch (result) {
      case TomSecretsAttached(:final channel):
        await _attach(channel);
      case TomSecretsNoService():
        _set(TomSecretsConnectionPhase.noService);
      case TomSecretsNotSetUp():
        _firstRunOpen = true;
        _set(TomSecretsConnectionPhase.notSetUp);
      case TomSecretsClaimNeeded():
        _set(TomSecretsConnectionPhase.claimNeeded);
      case TomSecretsCannotStart(:final message):
        _message = message;
        _set(TomSecretsConnectionPhase.cannotStart);
      case TomSecretsServiceStartFailed(:final message):
        _message = message;
        _set(TomSecretsConnectionPhase.startFailed);
    }
  }

  Future<void> _attach(TomSecretsAdminChannel channel) async {
    await _subscription?.cancel();
    await _channel?.close();
    _channel = channel;
    _message = null;
    _phase = TomSecretsConnectionPhase.attached;
    _subscription = channel.events.listen(
      _onEvent,
      onDone: _onDropped,
      onError: (Object _) {},
    );
    try {
      await channel.request('subscribe');
      await refreshStatus();
    } on TomSecretsAdminException catch (e) {
      _message = e.message;
    }
    notifyListeners();
  }

  void _onEvent(Map<String, Object?> event) {
    switch (event['op']) {
      case 'locked':
        _setLocked(true);
      case 'unlocked':
        _setLocked(false);
        unawaited(refreshStatus().catchError((Object _) {}));
      case 'unlock_needed':
        _unlockNeeded = true;
        notifyListeners();
      case 'approval_needed':
        final id = event['approvalId'];
        if (id is String) _approvals.add(id);
        notifyListeners();
      case 'approval_closed':
        _approvals.remove(event['approvalId']);
        notifyListeners();
      case 'store_state':
        final state = TomSecretsStoreState.fromWire(event);
        _stores[state.name] = state;
        notifyListeners();
      case 'key_expiry':
        final key = event['key'];
        if (key is String) _expiring[key] = event;
        notifyListeners();
    }
    if (!_events.isClosed) _events.add(event);
  }

  void _onDropped() {
    if (_disposed) return;
    _channel = null;
    _approvals.clear();
    _setLocked(true, notify: false);
    _set(TomSecretsConnectionPhase.dropped);
  }

  void _setLocked(bool locked, {bool notify = true}) {
    _locked = locked;
    if (locked) _unlockNeeded = false;
    if (notify) notifyListeners();
  }

  void _set(TomSecretsConnectionPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// [bytes] as base64.
  static String base64Of(Uint8List bytes) => _base64.encode(bytes);

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    unawaited(_channel?.close());
    unawaited(_events.close());
    super.dispose();
  }
}

const _base64 = Base64Codec();
