// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The first screen of a phone that is not set up: pairing with a desktop
/// app (its Pairing screen shows the address, over the LAN or the VPN, and
/// the one-time code), or the primary set up by hand.
library;

import 'package:flutter/material.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import 'mobile_setup.dart';

/// Receives a pairing: the address and code of the giving desktop, this
/// device's name; answers the giver's name and the bundle. A test hands in
/// its own.
typedef TomSecretsMobileReceive =
    Future<({String giver, TomSecretsPairingBundle bundle})> Function({
      required String address,
      required int port,
      required TomSecretsPairingCode code,
      required String device,
    });

/// The real pairing: `tomSecretsReceivePairingForSetup` (which refuses a
/// bundle without the primary or its token). The phone keeps no trust
/// material: it approves nothing and is not an approval link's peer.
Future<({String giver, TomSecretsPairingBundle bundle})>
tomSecretsMobileReceive({
  required String address,
  required int port,
  required TomSecretsPairingCode code,
  required String device,
}) async {
  final receipt = await tomSecretsReceivePairingForSetup(
    address: address,
    port: port,
    code: code,
    device: device,
  );
  return (giver: receipt.giver, bundle: receipt.bundle);
}

/// The setup screen; [onSetUp] runs once the phone is set up.
class TomSecretsMobileSetupScreen extends StatefulWidget {
  /// The screen writing into [setup].
  const TomSecretsMobileSetupScreen({
    super.key,
    required this.setup,
    required this.onSetUp,
    this.receive = tomSecretsMobileReceive,
  });

  /// Where the setup is kept.
  final TomSecretsMobileSetup setup;

  /// Called once the phone is set up.
  final VoidCallback onSetUp;

  /// How a pairing is received.
  final TomSecretsMobileReceive receive;

  @override
  State<TomSecretsMobileSetupScreen> createState() => _SetupState();
}

class _SetupState extends State<TomSecretsMobileSetupScreen> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  final _device = TextEditingController();
  final _locator = TextEditingController();
  final _token = TextEditingController();
  bool _byHand = false;
  bool _busy = false;
  String? _error;
  String? _received;

  @override
  void dispose() {
    for (final c in [_address, _code, _device, _locator, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pair() async {
    final device = _device.text.trim();
    if (device.isEmpty) {
      setState(() => _error = 'Name this device (e.g. "iphone").');
      return;
    }
    final (String, int) at;
    final TomSecretsPairingCode code;
    try {
      at = tomSecretsParsePairingAddress(_address.text);
      code = TomSecretsPairingCode.parse(_code.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final receipt = await widget.receive(
        address: at.$1,
        port: at.$2,
        code: code,
        device: device,
      );
      await widget.setup.applyPairing(receipt.bundle, device: device);
      setState(
        () => _received =
            'Received from ${receipt.giver}: '
            '${[for (final v in receipt.bundle.vaults) v.name].join(', ')}.',
      );
      widget.onSetUp();
    } on TomSecretsPairingException catch (e) {
      setState(
        () => _error = switch (e.failure) {
          TomSecretsPairingFailure.wrongCode =>
            'Wrong code: the desktop closed its pairing window. Open a new '
                'one there and type its new code.',
          TomSecretsPairingFailure.declined =>
            'The desktop declined: nothing was received.',
          TomSecretsPairingFailure.refused => 'Not set up: ${e.message}.',
          _ => 'The pairing failed: ${e.message}',
        },
      );
    } on Object catch (e) {
      setState(() => _error = 'The pairing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setUpByHand() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.setup.setUpByHand(
        locator: _locator.text,
        token: _token.text,
        device: _device.text.trim().isEmpty ? 'phone' : _device.text,
      );
      widget.onSetUp();
    } on TomSecretsLocatorException catch (e) {
      setState(() => _error = e.message);
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up Tom Secrets Manager')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'The vaults stay on GitHub; this device fetches them into its '
              'memory when you unlock and keeps no copy. Its keys come from '
              'your desktop app by pairing; the master password never '
              'travels: you type it here once.',
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              key: const Key('tsm-mobile-setup-mode'),
              segments: const [
                ButtonSegment(value: false, label: Text('Pair with a desktop')),
                ButtonSegment(value: true, label: Text('By hand')),
              ],
              selected: {_byHand},
              onSelectionChanged: (s) => setState(() => _byHand = s.single),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('tsm-mobile-setup-device'),
              controller: _device,
              decoration: const InputDecoration(
                labelText: 'This device\'s name',
                hintText: 'iphone',
              ),
            ),
            if (!_byHand) ...[
              const SizedBox(height: 8),
              const Text(
                'On the desktop: Pairing › "Pair another device". Type the '
                'address and the code it shows (the same LAN, or the VPN).',
              ),
              TextField(
                key: const Key('tsm-mobile-setup-address'),
                controller: _address,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: '10.8.0.2:47900',
                ),
              ),
              TextField(
                key: const Key('tsm-mobile-setup-code'),
                controller: _code,
                decoration: const InputDecoration(labelText: 'Code'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('tsm-mobile-setup-pair'),
                onPressed: _busy ? null : _pair,
                child: const Text('Pair'),
              ),
            ] else ...[
              const SizedBox(height: 8),
              const Text(
                'A primary vault without a key file or outer encryption: its '
                'location and a fine-grained GitHub token for its repository.',
              ),
              TextField(
                key: const Key('tsm-mobile-setup-locator'),
                controller: _locator,
                decoration: const InputDecoration(
                  labelText: 'Primary vault',
                  hintText: 'github:owner/repository/primary.kdbx',
                ),
              ),
              TextField(
                key: const Key('tsm-mobile-setup-token'),
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'GitHub token'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('tsm-mobile-setup-save'),
                onPressed: _busy ? null : _setUpByHand,
                child: const Text('Set up'),
              ),
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_received != null) Text(_received!),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error,
                  key: const Key('tsm-mobile-setup-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
