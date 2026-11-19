// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The tray or menu bar, the window and system notifications (part-app,
/// "Tray and menu bar", "Its own lifetime", Notifications), each over its
/// plugin and behind a port of `tom_secrets_ui` (DP-32).
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// The tray icon over `tray_manager`: the macOS menu bar (a template image),
/// the Windows notification area (an ICO), the Linux tray
/// (StatusNotifierItem through AppIndicator). A click opens the menu.
final class TomSecretsPluginTray with TrayListener implements TomSecretsTray {
  /// The tray; [iconFor] names the icon asset of each state.
  TomSecretsPluginTray({String Function(TomSecretsTrayState state)? iconFor})
    : _iconFor = iconFor ?? tomSecretsTrayIcon {
    trayManager.addListener(this);
  }

  final String Function(TomSecretsTrayState state) _iconFor;
  TomSecretsTrayState? _shown;
  final Map<String, void Function()> _actions = {};

  @override
  Future<void> update({
    required TomSecretsTrayState state,
    required String tooltip,
    required List<TomSecretsTrayItem> items,
  }) async {
    if (_shown != state) {
      await trayManager.setIcon(_iconFor(state), isTemplate: Platform.isMacOS);
      _shown = state;
    }
    if (!Platform.isLinux) await trayManager.setToolTip(tooltip);
    _actions.clear();
    final menu = <MenuItem>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.separator) {
        menu.add(MenuItem.separator());
        continue;
      }
      final key = 'item-$i';
      if (item.onSelected != null) _actions[key] = item.onSelected!;
      menu.add(
        MenuItem(
          key: key,
          label: item.label,
          disabled: item.onSelected == null,
        ),
      );
    }
    await trayManager.setContextMenu(Menu(items: menu));
  }

  @override
  void onTrayIconMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) => _actions[menuItem.key]?.call();

  @override
  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}

/// The tray icon asset of [state]: a PNG on macOS and Linux, an ICO on
/// Windows (this package's `assets/tray/`).
String tomSecretsTrayIcon(TomSecretsTrayState state) =>
    'packages/tom_secrets_desktop/assets/tray/${state.name}'
    '${Platform.isWindows ? '.ico' : '.png'}';

/// The window over `window_manager`: closing it hides it, so the app keeps
/// running in the tray (DP-30); without a tray (a Linux desktop with no
/// StatusNotifierItem host) closing minimises it instead, so it stays
/// reachable; [quit] ends the app.
final class TomSecretsPluginWindow
    with WindowListener
    implements TomSecretsWindowHost {
  TomSecretsPluginWindow._(this.hideOnClose);

  /// Whether closing hides the window (a tray is there to bring it back) or
  /// minimises it.
  bool hideOnClose;

  /// Sets the window up (title, size, closing hides it) and shows it unless
  /// [hidden] (a start at login).
  static Future<TomSecretsPluginWindow> create({
    required String title,
    bool hidden = false,
    bool hideOnClose = true,
  }) async {
    await windowManager.ensureInitialized();
    final window = TomSecretsPluginWindow._(hideOnClose);
    windowManager.addListener(window);
    await windowManager.setPreventClose(true);
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: title,
        size: const Size(1280, 820),
        minimumSize: const Size(960, 600),
        center: true,
      ),
      () async {
        if (!hidden) {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    );
    return window;
  }

  @override
  void onWindowClose() =>
      unawaited(hideOnClose ? hide() : windowManager.minimize());

  @override
  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<bool> isVisible() => windowManager.isVisible();

  @override
  Future<void> quit() async {
    windowManager.removeListener(this);
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }
}

/// System notifications over `flutter_local_notifications` (macOS
/// UserNotifications, Windows toasts, Linux through the desktop's
/// notification service). A click runs the notification's click, a button
/// its action. macOS needs a button's category registered at the start:
/// [actionCategories] names every one the app shows.
final class TomSecretsPluginNotifier implements TomSecretsNotifier {
  TomSecretsPluginNotifier._(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;
  final Map<int, void Function()> _clicks = {};
  final Map<int, Map<String, void Function()>> _actions = {};
  int _next = 1;

  /// The notification buttons the app shows, by their action id with their
  /// label: macOS takes only the buttons of a category registered at the
  /// start, one category per button here.
  static const actionCategories = {
    'turn-off-breach-check': 'Turn off breach check',
  };

  /// The Windows app user model id and the toast activator's GUID: the app's
  /// own, fixed, so Windows ties its notifications to it.
  static const windowsAppId = 'AlTheBear.TomSecretsManager';

  /// See [windowsAppId].
  static const windowsGuid = '3b3e2ab4-5d5a-4b7e-9c0a-6f1e8d2c4a91';

  /// Sets notifications up for [appName].
  static Future<TomSecretsPluginNotifier> create(String appName) async {
    final plugin = FlutterLocalNotificationsPlugin();
    final notifier = TomSecretsPluginNotifier._(plugin);
    await plugin.initialize(
      settings: InitializationSettings(
        macOS: DarwinInitializationSettings(
          notificationCategories: [
            for (final MapEntry(key: id, value: label)
                in actionCategories.entries)
              DarwinNotificationCategory(
                id,
                actions: [DarwinNotificationAction.plain(id, label)],
              ),
          ],
        ),
        linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: appName,
          appUserModelId: windowsAppId,
          guid: windowsGuid,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final id = response.id;
        if (id == null) return;
        final actions = notifier._actions.remove(id);
        final click = notifier._clicks.remove(id);
        final action = response.actionId;
        if (action != null && action.isNotEmpty && actions != null) {
          actions[action]?.call();
        } else {
          click?.call();
        }
      },
    );
    return notifier;
  }

  @override
  Future<void> notify({
    required String title,
    required String body,
    void Function()? onClick,
    List<TomSecretsNotificationAction> actions = const [],
  }) async {
    final id = _next++;
    if (onClick != null) _clicks[id] = onClick;
    if (actions.isNotEmpty) {
      _actions[id] = {for (final a in actions) a.id: a.onPressed};
    }
    // macOS shows the buttons of one registered category.
    final category =
        actions.length == 1 && actionCategories.containsKey(actions.single.id)
        ? actions.single.id
        : null;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        macOS: DarwinNotificationDetails(categoryIdentifier: category),
        linux: LinuxNotificationDetails(
          actions: [
            for (final a in actions)
              LinuxNotificationAction(key: a.id, label: a.label),
          ],
        ),
        windows: WindowsNotificationDetails(
          actions: [
            for (final a in actions)
              WindowsAction(content: a.label, arguments: a.id),
          ],
        ),
      ),
    );
  }
}
