// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// `ServiceConnection` of part-app's State: the admin connection to the
/// secrets service, its event stream and what the app knows of the service
/// (locked or not, the stores' states, waiting approvals, keys due).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_client/admin.dart'
    show
        TomSecretsAdminException,
        TomSecretsUnlockBundle,
        tomSecretsRandomBytes;

import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsOfflineCache;

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
    this.rewrittenHead,
    this.fetchedBytes,
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
      rewrittenHead: (m['rewritten'] as Map?)?['head'] as String?,
      fetchedBytes: m['fetchedBytes'] is int ? m['fetchedBytes']! as int : null,
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

  /// The head of its branch on GitHub, rewritten without a compaction (a
  /// force push), while the service waits for the user's answer
  /// (`history.resolve`, protocol.md 6.4); null otherwise.
  final String? rewrittenHead;

  /// The size of the file as last fetched, in bytes, when the host reports
  /// it (the mobile app: every unlock fetches it again, on mobile data too).
  final int? fetchedBytes;

  /// Whether it is served from its offline copy.
  bool get isOffline =>
      state == 'offline' || state == 'token_expired' || source == 'cache';

  /// Whether it is served from an offline copy older than the stale age
  /// (`TomSecretsOfflineCache.defaultStaleAfter`, 7 days) at [now]: the
  /// app warns that the copy may be out of date (part-key-rotation).
  bool isStaleAt(DateTime now) {
    final at = fetchedAt;
    return isOffline &&
        at != null &&
        now.difference(at) > TomSecretsOfflineCache.defaultStaleAfter;
  }

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
  final Map<String, TomSecretsApprovalPrompt> _approvals = {};
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

  /// The prompts waiting for this app's answer, in the order they came.
  List<TomSecretsApprovalPrompt> get prompts => _approvals.values.toList();

  /// The waiting prompt [approvalId], or null.
  TomSecretsApprovalPrompt? prompt(String approvalId) => _approvals[approvalId];

  /// Answers the prompt [approvalId] (`approve`, protocol.md 7.2): with
  /// [decision] (`once`, `always`, `folder`, `never`) for [secret] (`ref`,
  /// `store`, `all`), below [folder] for `folder`, pinned by [pin]. For an
  /// `always` of a prompt that asked for a client token the app makes the
  /// token (32 random bytes, protocol.md 7.4) and its service signs the
  /// grant. Throws `TomSecretsAdminException` (`not_found` when the prompt
  /// ended meanwhile).
  Future<void> approve(
    String approvalId, {
    required String decision,
    String secret = 'ref',
    String? folder,
    String? pin,
    bool sshHost = false,
    bool withParent = false,
    String? pick,
  }) async {
    final waiting = _approvals[approvalId];
    final token = decision == 'always' && (waiting?.wantClientToken ?? false)
        ? base64Of(tomSecretsRandomBytes(32))
        : null;
    await request('approve', {
      'approvalId': approvalId,
      'decision': decision,
      'secret': secret,
      'folder': ?folder,
      'pin': ?pin,
      'clientToken': ?token,
      if (sshHost) 'sshHost': true,
      if (withParent) 'withParent': true,
      'pick': ?pick,
    });
    _approvals.remove(approvalId);
    notifyListeners();
  }

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

  /// Unlocks [vault] (the primary) with the OS unlock's key [bundle]
  /// (protocol.md 6.4). Throws `TomSecretsAdminException` (`denied`, reason
  /// `bad_password` when the vault was re-keyed, `bad_bundle`).
  Future<void> unlockWithBundle(
    String vault,
    TomSecretsUnlockBundle bundle,
  ) async {
    final channel = _channel;
    if (channel == null || _phase != TomSecretsConnectionPhase.attached) {
      throw TomSecretsAdminException(
        'not_running',
        'not attached to the service',
      );
    }
    await channel.unlockWithBundle(vault, bundle);
    _locked = false;
    _unlockNeeded = false;
    notifyListeners();
    await refreshStatus();
  }

  /// The service's start (`statusReport.service.start`, milliseconds since
  /// the epoch), or null before the first status.
  int? get serviceStart {
    final start = (_report['service'] as Map?)?['start'];
    return start is int ? start : null;
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
    await host.serviceStopped();
  }

  /// Fetches every store now.
  Future<void> reload() => request('reload');

  /// Answers the rewritten branch of [store] (`history.resolve`): with
  /// [takeRemote] the file on GitHub is taken as it is and the refused
  /// change dropped, otherwise this copy is merged over it and committed on
  /// top. Answers how many conflict records the merge wrote. Throws
  /// `TomSecretsAdminException`.
  Future<int> resolveRewritten(String store, {required bool takeRemote}) async {
    final answer = await request('history.resolve', {
      'store': store,
      'take': takeRemote ? 'remote' : 'merge',
    });
    await refreshStatus();
    return answer['conflicts'] is int ? answer['conflicts']! as int : 0;
  }

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
        final prompt = TomSecretsApprovalPrompt.fromEvent(event);
        if (prompt != null) _approvals[prompt.approvalId] = prompt;
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

/// What an ssh-agent prompt is about (`approval_needed.ssh`, protocol.md
/// 7.6).
final class TomSecretsSshPromptInfo {
  const TomSecretsSshPromptInfo._({
    required this.keyFingerprint,
    required this.keyType,
    required this.title,
    required this.hostKeyFingerprint,
    required this.hostNames,
    required this.forwarded,
    required this.purpose,
    required this.namespace,
  });

  /// The `ssh` member [json], or null when there is none.
  static TomSecretsSshPromptInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    return TomSecretsSshPromptInfo._(
      keyFingerprint: json['key'] as String? ?? '',
      keyType: json['keyType'] as String? ?? '',
      title: json['title'] as String?,
      hostKeyFingerprint: json['host'] as String?,
      hostNames: (json['hostNames'] as List? ?? const []).cast<String>(),
      forwarded: json['forwarded'] == true,
      purpose: json['purpose'] as String? ?? 'other',
      namespace: json['namespace'] as String?,
    );
  }

  /// The key's fingerprint (`SHA256:…`).
  final String keyFingerprint;

  /// The key's type (`ssh-ed25519`, …).
  final String keyType;

  /// The key entry's title.
  final String? title;

  /// The destination's host key fingerprint, or null when the connection
  /// is not bound to one.
  final String? hostKeyFingerprint;

  /// The destination's names in `known_hosts`.
  final List<String> hostNames;

  /// Whether the request came over a forwarded agent connection.
  final bool forwarded;

  /// `userauth`, `sshsig` or `other`.
  final String purpose;

  /// An `SSHSIG` signature's namespace (`git`, `file`, …).
  final String? namespace;

  /// What the signature is for, in words.
  String get purposeText => switch (purpose) {
    'userauth' => 'to log in',
    'sshsig' =>
      namespace == 'git'
          ? 'to sign a git commit or tag'
          : 'to sign${namespace == null ? '' : ' ($namespace)'}',
    _ => 'to sign',
  };

  /// The destination in words: its names, else its host key, else unknown.
  String get destinationText => hostNames.isNotEmpty
      ? hostNames.join(', ')
      : hostKeyFingerprint ?? 'not told (an older ssh or no login)';
}

/// A request waiting for an approval (`approval_needed`, protocol.md 6.5,
/// 7.2): who asks, on which host, for which secrets.
@immutable
final class TomSecretsApprovalPrompt {
  const TomSecretsApprovalPrompt._({
    required this.approvalId,
    required this.host,
    required this.identity,
    required this.refs,
    required this.resolved,
    required this.approvalCode,
    required this.wantClientToken,
    required this.remote,
    required this.ssh,
    required this.confirmOnly,
    required this.pick,
    required this.url,
    required this.browser,
  });

  /// The prompt of [event], or null when it names no approval.
  static TomSecretsApprovalPrompt? fromEvent(Map<String, Object?> event) {
    final id = event['approvalId'];
    if (id is! String) return null;
    return TomSecretsApprovalPrompt._(
      approvalId: id,
      host: event['host'] as String? ?? '',
      identity: (event['identity'] as Map? ?? const {}).cast<String, Object?>(),
      refs: (event['refs'] as List? ?? const []).cast<String>(),
      resolved: [
        for (final r in (event['resolved'] as List? ?? const []).cast<Map>())
          (
            store: r['store'] as String? ?? '',
            path: r['path'] as String? ?? '',
            kind: r['kind'] as String? ?? '',
          ),
      ],
      approvalCode: event['approvalCode'] as String?,
      wantClientToken: event['wantClientToken'] == true,
      remote: event['hostHint'] == 'remote',
      ssh: TomSecretsSshPromptInfo.fromJson(event['ssh']),
      confirmOnly: event['confirmOnly'] == true,
      pick: event['pick'] is List
          ? [
              for (final p in (event['pick'] as List).cast<Map>())
                (
                  entryId: p['entryId'] as String? ?? '',
                  title: p['title'] as String? ?? '',
                  userName: p['userName'] as String? ?? '',
                  matchedUrl: p['matchedUrl'] as String? ?? '',
                ),
            ]
          : null,
      url: event['url'] as String?,
      browser: event['browser'] == true,
    );
  }

  /// The approval's id.
  final String approvalId;

  /// The host the request waits on.
  final String host;

  /// Who asks, as that host's service measured it (protocol.md 7.1).
  final Map<String, Object?> identity;

  /// The references asked for, canonical.
  final List<String> refs;

  /// The entries they resolve to.
  final List<({String store, String path, String kind})> resolved;

  /// The approval code the host shows, or null.
  final String? approvalCode;

  /// Whether the client asked for a client token (protocol.md 7.4).
  final bool wantClientToken;

  /// Whether the client connected from another machine (`hostHint`).
  final bool remote;

  /// For an ssh-agent signature: the key, the destination and the purpose
  /// (protocol.md 7.6); null for a value request.
  final TomSecretsSshPromptInfo? ssh;

  /// A confirmation of one signature a grant allows: answered once or
  /// never, nothing written.
  final bool confirmOnly;

  /// A helper's pick prompt (git asks one credential, protocol.md 5.5): the
  /// logins of the host to pick from; null for any other prompt.
  final List<
    ({String entryId, String title, String userName, String matchedUrl})
  >?
  pick;

  /// The page or host a pick or browser prompt's logins match.
  final String? url;

  /// A browser prompt (protocol.md 5.5, DP-44): the browser extension asks
  /// for the logins of the page [url] ([resolved]); a lasting answer holds
  /// for the browser that started its host ([parentExe]).
  final bool browser;

  /// The site of [url] (its host), or the address as written.
  String get site {
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    return host.isEmpty ? url ?? '' : host;
  }

  /// The client's executable.
  String get exe => identity['exe'] as String? ?? '';

  /// Its script, for an interpreted client, or null.
  String? get script => identity['script'] as String?;

  /// Its interpreter, for an interpreted client, or null.
  String? get interpreter => identity['interpreter'] as String?;

  /// Its working directory, or null.
  String? get cwd => identity['cwd'] as String?;

  /// Its arguments.
  List<String> get args =>
      (identity['args'] as List? ?? const []).map((a) => '$a').toList();

  /// Its parent process's executable, or null.
  String? get parentExe => (identity['parent'] as Map?)?['exe'] as String?;

  /// Who asks, in one line: the script with its interpreter, or the
  /// executable.
  String get who => script != null
      ? '${interpreter ?? exe} $script'
      : exe.isEmpty
      ? 'an unknown program'
      : exe;

  /// The folder a `folder` decision suggests: the script's, else the
  /// executable's.
  String get suggestedFolder {
    final path = script ?? exe;
    final cut = path.lastIndexOf(RegExp(r'[/\\]'));
    return cut > 0 ? path.substring(0, cut) : (cwd ?? path);
  }
}
