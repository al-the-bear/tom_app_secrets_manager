// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// What the app does with the host's capabilities as the service's state
/// changes (part-app): the tray icon and its menu, the system notification
/// for an unlock request while the window is closed, keeping the window out
/// of screen capture (DP-33), and starting at login on the first start
/// (DP-30).
library;

import 'dart:async';

import 'ports/desktop_ports.dart';
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
  /// A bridge for [host] following [connection].
  TomSecretsHostBridge({required this.host, required this.connection});

  /// The host.
  final TomSecretsHost host;

  /// The connection.
  final TomSecretsServiceConnection connection;

  StreamSubscription<Map<String, Object?>>? _events;
  bool _started = false;

  /// Applies the device's settings and starts following the connection.
  void start() {
    if (_started) return;
    _started = true;
    connection.addListener(_update);
    _events = connection.events.listen(_onEvent);
    unawaited(applyCaptureSetting());
    unawaited(_initLoginItem());
    _update();
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

  void _update() {
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
          if (attached && !c.locked)
            TomSecretsTrayItem(
              'Lock',
              onSelected: () => unawaited(c.lock().catchError((Object _) {})),
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
              onSelected: () =>
                  unawaited(c.stopService().catchError((Object _) {})),
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
    if (event['op'] != 'unlock_needed') return;
    final notifier = host.notifier;
    final window = host.window;
    if (notifier == null) return;
    if (window != null && await window.isVisible()) return;
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
    unawaited(_events?.cancel());
  }
}
