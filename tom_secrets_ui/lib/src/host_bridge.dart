// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// What the app does with the host's capabilities as the service's state
/// changes (part-app): the tray icon and its menu, the system notifications
/// for an unlock request and an approval prompt while the window is closed
/// (DP-31), keeping the window out
/// of screen capture (DP-33), and starting at login on the first start
/// (DP-30).
library;

import 'dart:async';

import 'ports/desktop_ports.dart';
import 'state/auto_type.dart';
import 'state/health.dart';
import 'state/os_unlock.dart';
import 'state/proposals.dart';
import 'state/reminders.dart';
import 'state/service_connection.dart';

/// The device preference keys the bridge keeps.
abstract final class TomSecretsHostPreferenceKeys {
  /// Whether the window is kept out of screen capture: `on` (the default,
  /// DP-33) or `off`.
  static const captureExcluded = 'window.captureExcluded';

  /// Set once start-at-login was switched on at the first start (DP-30), so
  /// the user's own choice later is never overridden.
  static const loginItemSet = 'loginItem.initialised';
}

/// Connects the host's capabilities to the connection's state.
final class TomSecretsHostBridge {
  /// A bridge for [host] following [connection]; [osUnlock] keeps the OS
  /// unlock's items; [health]'s breach-check runs become notifications.
  TomSecretsHostBridge({
    required this.host,
    required this.connection,
    this.osUnlock,
    this.health,
    this.quickAccess,
  });

  /// The host.
  final TomSecretsHost host;

  /// The connection.
  final TomSecretsServiceConnection connection;

  /// The OS unlock, or null.
  final TomSecretsOsUnlock? osUnlock;

  /// The health report, or null.
  final TomSecretsHealth? health;

  /// Quick access and auto-type, or null.
  final TomSecretsQuickAccess? quickAccess;
  TomSecretsAutoTypeOutcome? _notifiedOutcome;

  StreamSubscription<TomSecretsBreachRun>? _breachRuns;

  StreamSubscription<Map<String, Object?>>? _events;
  StreamSubscription<TomSecretsSessionEvent>? _session;
  int? _lastStart;
  Timer? _daily;
  bool _reminding = false;
  bool _started = false;

  /// The clock of the daily reminder (tests set it).
  DateTime Function() clock = DateTime.now;

  /// Applies the device's settings and starts following the connection.
  void start() {
    if (_started) return;
    _started = true;
    connection.addListener(_update);
    _events = connection.events.listen(_onEvent);
    _session = host.sessionEvents?.events.listen(
      (e) => unawaited(onSessionEvent(e)),
    );
    // A host without notifications (a phone) shows the runs in its shell.
    if (host.notifier != null) {
      _breachRuns = health?.runs.listen(
        (run) => unawaited(notifyBreachRun(run)),
      );
    }
    unawaited(applyCaptureSetting());
    unawaited(_initLoginItem());
    // While the app runs, a due key is notified once a day (part-key-
    // rotation, Reminders); the hour checks for the next day's.
    _daily = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(remind()),
    );
    quickAccess?.addListener(_onQuickAccess);
    _update();
  }

  /// An auto-type run that did not type everything is said in a
  /// notification (the window is hidden while it types).
  void _onQuickAccess() {
    final outcome = quickAccess?.lastOutcome;
    if (outcome == null || identical(outcome, _notifiedOutcome)) return;
    _notifiedOutcome = outcome;
    if (outcome.result == TomSecretsAutoTypeResult.typed) return;
    final notifier = host.notifier;
    if (notifier == null) return;
    unawaited(
      notifier.notify(
        title: outcome.result == TomSecretsAutoTypeResult.stopped
            ? 'Auto-type stopped'
            : 'Auto-type did not start',
        body: outcome.message ?? '',
        onClick: host.window == null
            ? null
            : () => unawaited(host.window!.show()),
      ),
    );
  }

  /// Shows a run of the breach check as a notification (DP-39), whether the
  /// window is open or not, with the action "Turn off breach check"; a
  /// click opens the window at Health. Never a password or a title.
  Future<void> notifyBreachRun(TomSecretsBreachRun run) async {
    final notifier = host.notifier;
    final health = this.health;
    if (notifier == null || health == null) return;
    final window = host.window;
    await notifier.notify(
      title: run.title,
      body: run.body,
      onClick: () {
        health.requestShow();
        if (window != null) unawaited(window.show());
      },
      actions: [
        TomSecretsNotificationAction(
          id: 'turn-off-breach-check',
          label: 'Turn off breach check',
          onPressed: () => unawaited(health.setBreachEnabled(false)),
        ),
      ],
    );
  }

  /// Notifies the keys due, once a day; a click opens the window.
  Future<bool> remind() async {
    final notifier = host.notifier;
    if (notifier == null || connection.expiringKeys.isEmpty || _reminding) {
      return false;
    }
    _reminding = true;
    try {
      final window = host.window;
      return await TomSecretsReminders(
        connection,
        host.preferences,
      ).notifyDaily(
        notifier,
        now: clock(),
        onClick: window == null ? null : () => unawaited(window.show()),
      );
    } finally {
      _reminding = false;
    }
  }

  /// Whether the window is to be kept out of capture (default on, DP-33).
  bool get captureExcluded =>
      host.preferences.read(TomSecretsHostPreferenceKeys.captureExcluded) !=
      'off';

  /// Applies [captureExcluded] to the window.
  Future<bool> applyCaptureSetting() => host.captureGuard.supported
      ? host.captureGuard.setExcluded(captureExcluded)
      : Future.value(false);

  Future<void> _initLoginItem() async {
    final item = host.loginItem;
    if (item == null) return;
    final prefs = host.preferences;
    if (prefs.read(TomSecretsHostPreferenceKeys.loginItemSet) != null) return;
    try {
      await item.setEnabled(true);
      await prefs.write(TomSecretsHostPreferenceKeys.loginItemSet, 'yes');
    } on Object {
      // A platform that refuses leaves it off; the setting can be tried
      // again from the Settings screen.
    }
  }

  /// Stops the service; its session's OS unlock items are forgotten.
  Future<void> stopService() async {
    await osUnlock?.forgetSession();
    try {
      await connection.stopService();
    } on Object {
      // Stopped already, or it refuses: the next start asks for the unlock.
    }
  }

  /// The desktop session's [event] (the app is the sensor, part-service):
  /// the screen lock locks the service in lock mode (c), sleep when the
  /// service's settings say `lockOnSleep`.
  Future<void> onSessionEvent(TomSecretsSessionEvent event) async {
    final c = connection;
    if (c.phase != TomSecretsConnectionPhase.attached || c.locked) return;
    try {
      switch (event) {
        case TomSecretsSessionEvent.screenLocked:
          if (c.lockMode == 'c') await c.lock();
        case TomSecretsSessionEvent.sleep:
          final settings = await c.request('settings.get');
          final lock =
              ((settings['device'] as Map?)?['serviceLock'] as Map?) ??
              const {};
          if (lock['lockOnSleep'] == true) await c.lock();
      }
    } on Object {
      // Locked meanwhile, or the service went away.
    }
  }

  void _update() {
    // A service of another start (started again, or after a crash) drops
    // the session items of the older one.
    final start = connection.serviceStart;
    if (start != null && start != _lastStart) {
      _lastStart = start;
      unawaited(osUnlock?.dropStale().catchError((Object _) {}));
    }
    // The keys due arrive with the status at the unlock, too.
    if (connection.expiringKeys.isNotEmpty) unawaited(remind());
    final tray = host.tray;
    if (tray == null) return;
    final c = connection;
    final attached = c.phase == TomSecretsConnectionPhase.attached;
    final state = !attached || c.locked
        ? (c.needsAttention
              ? TomSecretsTrayState.attention
              : TomSecretsTrayState.locked)
        : (c.needsAttention
              ? TomSecretsTrayState.attention
              : TomSecretsTrayState.unlocked);
    final window = host.window;
    unawaited(
      tray.update(
        state: state,
        tooltip: 'Tom Secrets Manager — ${statusLine()}',
        items: [
          if (window != null)
            TomSecretsTrayItem(
              'Open',
              onSelected: () => unawaited(window.show()),
            ),
          if (attached && !c.locked && quickAccess != null)
            TomSecretsTrayItem(
              'Quick access',
              onSelected: () => unawaited(quickAccess!.open()),
            ),
          if (attached && !c.locked)
            TomSecretsTrayItem(
              'Lock',
              onSelected: () => unawaited(c.lock().catchError((Object _) {})),
            ),
          if (attached && (osUnlock?.hasSession ?? false))
            TomSecretsTrayItem(
              'Lock completely (forget the ${osUnlock!.label} unlock)',
              onSelected: () => unawaited(
                osUnlock!.lockCompletely().catchError((Object _) {}),
              ),
            ),
          if (attached && c.locked && window != null)
            TomSecretsTrayItem(
              'Unlock…',
              onSelected: () => unawaited(window.show()),
            ),
          if (c.pendingApprovals > 0)
            TomSecretsTrayItem(
              '${c.pendingApprovals} approvals waiting',
              onSelected: window == null
                  ? null
                  : () => unawaited(window.show()),
            ),
          TomSecretsTrayItem(statusLine()),
          const TomSecretsTrayItem.separator(),
          if (window != null)
            TomSecretsTrayItem(
              'Quit the app (the service keeps running)',
              onSelected: () => unawaited(window.quit()),
            ),
          if (attached)
            TomSecretsTrayItem(
              'Stop the service',
              onSelected: () => unawaited(stopService()),
            ),
        ],
      ),
    );
  }

  /// The status line of the tray: the service, then the stores.
  String statusLine({DateTime? now}) {
    final c = connection;
    if (c.phase != TomSecretsConnectionPhase.attached) {
      return 'service not running';
    }
    if (c.locked) return 'locked';
    final stores = c.stores.values.toList();
    if (stores.isEmpty) return 'unlocked';
    final offline = stores.where((s) => s.isOffline).toList();
    if (offline.isEmpty) return '${stores.length} vaults synced';
    final first = offline.first;
    final at = first.fetchedAt;
    final age = at == null
        ? ''
        : ', copy from ${_age((now ?? DateTime.now()).difference(at))}';
    return '${offline.map((s) => s.name).join(', ')} offline$age';
  }

  static String _age(Duration d) => d.inHours < 1
      ? '${d.inMinutes} min ago'
      : d.inDays < 1
      ? '${d.inHours} h ago'
      : '${d.inDays} days ago';

  Future<void> _onEvent(Map<String, Object?> event) async {
    final op = event['op'];
    if (op == 'key_expiry') {
      await remind();
      return;
    }
    if (op != 'unlock_needed' && op != 'approval_needed' && op != 'proposal') {
      return;
    }
    final notifier = host.notifier;
    final window = host.window;
    if (notifier == null) return;
    if (window != null && await window.isVisible()) return;
    if (op == 'approval_needed') {
      // The notification only opens the window, where the prompt waits on
      // top; the decision is taken there, with the client shown in full
      // (DP-31). It never names a secret.
      final prompt = TomSecretsApprovalPrompt.fromEvent(event);
      if (prompt == null) return;
      await notifier.notify(
        title: 'Approve a request',
        body: prompt.browser
            ? 'The browser extension on ${prompt.host} asks for the logins '
                  'of ${prompt.site}.'
            : '${prompt.who} on ${prompt.host} asks for '
                  '${prompt.refs.length == 1 ? 'a secret' : '${prompt.refs.length} secrets'}.',
        onClick: window == null ? null : () => unawaited(window.show()),
      );
      return;
    }
    if (op == 'proposal') {
      // Never the password: the site and the user only.
      final proposal = TomSecretsProposal.fromEvent(event, 0);
      if (proposal == null) return;
      await notifier.notify(
        title: 'Save a login?',
        body:
            'A login for ${proposal.site} (${proposal.userName}) waits under '
            'Proposals.',
        onClick: window == null ? null : () => unawaited(window.show()),
      );
      return;
    }
    final identity = (event['identity'] as Map?)?.cast<String, Object?>();
    final who =
        identity?['exe'] ?? identity?['script'] ?? 'A program on this machine';
    await notifier.notify(
      title: 'Unlock the secrets',
      body: '$who waits for the secrets service to be unlocked.',
      onClick: window == null ? null : () => unawaited(window.show()),
    );
  }

  /// Stops following the connection.
  void dispose() {
    connection.removeListener(_update);
    _daily?.cancel();
    quickAccess?.removeListener(_onQuickAccess);
    unawaited(_breachRuns?.cancel());
    unawaited(_events?.cancel());
    unawaited(_session?.cancel());
  }
}
