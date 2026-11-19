// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The manager app's root: the controllers of part-app's State provided to
/// the widget tree, and the screen the connection's phase calls for.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsBreachCheck;

import 'host_bridge.dart';
import 'ports/desktop_ports.dart';
import 'screens/first_run_wizard.dart';
import 'screens/gate_screens.dart';
import 'screens/main_shell.dart';
import 'state/auto_type.dart';
import 'state/autofill.dart';
import 'state/first_run_model.dart';
import 'state/health.dart';
import 'state/os_unlock.dart';
import 'state/service_connection.dart';
import 'state/session_state.dart';
import 'widgets/style.dart';

/// The Tom Secrets Manager app over [host].
class TomSecretsApp extends StatefulWidget {
  /// The app; a test passes a [connection] it controls.
  const TomSecretsApp({super.key, required this.host, this.connection});

  /// The host's capabilities.
  final TomSecretsHost host;

  /// The connection, when the caller made it (tests); else one over the
  /// host's service.
  final TomSecretsServiceConnection? connection;

  @override
  State<TomSecretsApp> createState() => _TomSecretsAppState();
}

class _TomSecretsAppState extends State<TomSecretsApp> {
  late final TomSecretsServiceConnection _connection =
      widget.connection ?? TomSecretsServiceConnection(widget.host.service);
  late final TomSecretsSession _session = TomSecretsSession(
    _connection,
    widget.host.preferences,
    systemVaultsReadOnly: widget.host.systemVaultsReadOnly,
  );
  late final TomProtectedClipboard _clipboard = TomProtectedClipboard(
    port: widget.host.clipboard,
    clearAfter: widget.host.clipboardClearAfter,
  );
  late final TomSecretsOsUnlock _osUnlock = TomSecretsOsUnlock(
    connection: _connection,
    host: widget.host.osUnlock,
    preferences: widget.host.preferences,
  );
  late final TomSecretsAutofill? _autofill = widget.host.autofill == null
      ? null
      : TomSecretsAutofill(
          port: widget.host.autofill!,
          session: _session,
          preferences: widget.host.preferences,
        );
  // The host's breach check, else the range API over a client of the app's
  // own (closed with the app).
  late final TomSecretsBreachCheck? _ownBreachCheck =
      widget.host.breachCheck == null ? TomSecretsBreachCheck() : null;
  late final TomSecretsHealth _health = TomSecretsHealth(
    session: _session,
    preferences: widget.host.preferences,
    check: widget.host.breachCheck ?? _ownBreachCheck!,
  );
  late final TomSecretsQuickAccess _quickAccess = TomSecretsQuickAccess(
    session: _session,
    preferences: widget.host.preferences,
    keyboard: widget.host.keyboard,
    hotkeys: widget.host.hotkeys,
    window: widget.host.window,
    macOS: widget.host.macOS,
  );
  late final TomSecretsHostBridge _bridge = TomSecretsHostBridge(
    host: widget.host,
    connection: _connection,
    osUnlock: _osUnlock,
    health: _health,
    quickAccess: _quickAccess,
  );

  @override
  void initState() {
    super.initState();
    _bridge.start();
    _health.start();
    unawaited(_quickAccess.registerHotkeys());
    if (widget.connection == null) _connection.connect();
    unawaited(_autofill?.refresh());
  }

  @override
  void dispose() {
    _bridge.dispose();
    _health.dispose();
    _quickAccess.dispose();
    _ownBreachCheck?.close();
    _autofill?.dispose();
    _osUnlock.dispose();
    _session.dispose();
    if (widget.connection == null) _connection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<TomSecretsHost>.value(value: widget.host),
      ChangeNotifierProvider.value(value: _connection),
      ChangeNotifierProvider.value(value: _session),
      ChangeNotifierProvider.value(value: _osUnlock),
      ChangeNotifierProvider.value(value: _health),
      ChangeNotifierProvider.value(value: _quickAccess),
      // Null where the host has no AutoFill (watched as nullable).
      ChangeNotifierProvider<TomSecretsAutofill?>.value(value: _autofill),
    ],
    child: MaterialApp(
      title: 'Tom Secrets Manager',
      debugShowCheckedModeBanner: false,
      theme: tomSecretsTheme(Brightness.light),
      darkTheme: tomSecretsTheme(Brightness.dark),
      home: _Gate(clipboard: _clipboard),
    ),
  );
}

class _Gate extends StatelessWidget {
  const _Gate({required this.clipboard});

  final TomProtectedClipboard clipboard;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final keyFiles = context.read<TomSecretsHost>().keyFiles;
    if (c.firstRunOpen) return const _FirstRunGate();
    return switch (c.phase) {
      TomSecretsConnectionPhase.attached =>
        c.locked
            ? TomSecretsUnlockScreen(keyFiles: keyFiles)
            : (context.read<TomSecretsHost>().shell?.call(context, clipboard) ??
                  TomSecretsMainShell(clipboard: clipboard)),
      TomSecretsConnectionPhase.claimNeeded => TomSecretsClaimScreen(
        keyFiles: keyFiles,
      ),
      _ => const TomSecretsConnectionScreen(),
    };
  }
}

/// The First run wizard, once the host handed over where it writes.
class _FirstRunGate extends StatefulWidget {
  const _FirstRunGate();

  @override
  State<_FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<_FirstRunGate> {
  TomSecretsFirstRunModel? _model;
  Object? _failure;

  @override
  void initState() {
    super.initState();
    final host = context.read<TomSecretsHost>();
    final connection = context.read<TomSecretsServiceConnection>();
    host.service.firstRun().then(
      (firstRun) {
        if (!mounted) return;
        setState(
          () => _model = TomSecretsFirstRunModel(
            firstRun: firstRun,
            connection: connection,
            discovery: host.pairingDiscovery,
            ownAddresses: host.pairingAddresses,
          ),
        );
      },
      onError: (Object e) {
        if (mounted) setState(() => _failure = e);
      },
    );
  }

  @override
  void dispose() {
    _model?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    if (model != null) return TomSecretsFirstRunWizard(model: model);
    return TomSecretsGateCard(
      title: 'Set up Tom Secrets Manager',
      icon: Icons.key_rounded,
      children: [
        if (_failure == null)
          const Center(child: CircularProgressIndicator())
        else
          Text('The first run cannot start: $_failure'),
      ],
    );
  }
}
