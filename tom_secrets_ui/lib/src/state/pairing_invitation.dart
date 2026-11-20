// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The pairing invitation (DP-56, DP-61): what the giving desktop's QR code
/// carries — the addresses its pairing window listens on, its port and the
/// one-time code — as one line of text,
///
///     tsm-pair:<address>[,<address>…]:<port>?code=<code>
///
/// an IPv6 address in brackets (`tsm-pair:[fd00::2],10.8.0.2:47900?code=…`).
/// A window that also waits on a relay adds its id (part-relay),
/// `…?code=<code>&relay=github%3Aowner%2Frepo`; one on a relay alone has no
/// addresses: `tsm-pair:relay?code=<code>&relay=<id>`.
/// The phone scans it and connects to the address nearest its own, as it
/// does with a window found on the LAN; typing the address and code is the
/// fallback. The code works once, so the text is no secret once used, but a
/// photo of an open window's QR code is as good as the typed code.
library;

import 'dart:io';

import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsPairingCode, TomSecretsRelayId;

import '../ports/pairing_discovery.dart';

/// The scheme of the invitation text.
const String tomSecretsPairingScheme = 'tsm-pair';

/// An open pairing window, as its QR code tells it.
final class TomSecretsPairingInvitation {
  /// The window at [addresses] on [port] with [code], also waiting on
  /// [relay]; at least one address or a relay.
  TomSecretsPairingInvitation({
    required List<String> addresses,
    required this.port,
    required this.code,
    this.relay,
  }) : addresses = List.unmodifiable(addresses) {
    if (this.addresses.isEmpty && relay == null) {
      throw ArgumentError.value(addresses, 'addresses', 'empty, and no relay');
    }
  }

  /// The relay the window also waits on (the same nameplate as the code's
  /// number), or null.
  final TomSecretsRelayId? relay;

  /// The addresses the window listens on (IPv4 or IPv6, as text).
  final List<String> addresses;

  /// The window's port.
  final int port;

  /// The one-time code.
  final TomSecretsPairingCode code;

  /// The text of the QR code.
  String get text {
    final via = relay == null
        ? ''
        : '&relay=${Uri.encodeQueryComponent(relay!.text)}';
    if (addresses.isEmpty) {
      return '$tomSecretsPairingScheme:relay?code=${code.text}$via';
    }
    final hosts = [
      for (final a in addresses) a.contains(':') ? '[$a]' : a,
    ].join(',');
    return '$tomSecretsPairingScheme:$hosts:$port?code=${code.text}$via';
  }

  /// The invitation [text] holds; throws [FormatException] for any other
  /// text (another QR code, a damaged one, an address that is none).
  static TomSecretsPairingInvitation parse(String text) {
    final t = text.trim();
    const prefix = '$tomSecretsPairingScheme:';
    if (!t.startsWith(prefix)) {
      throw const FormatException('not a pairing code of Tom Secrets Manager');
    }
    final rest = t.substring(prefix.length);
    final query = rest.indexOf('?');
    if (query < 0) throw const FormatException('the pairing code has no code');
    final params = Uri.splitQueryString(rest.substring(query + 1));
    final codeText = params['code'];
    if (codeText == null) {
      throw const FormatException('the pairing code has no code');
    }
    final code = TomSecretsPairingCode.parse(codeText);
    final relayText = params['relay'];
    final relay = relayText == null ? null : TomSecretsRelayId.parse(relayText);
    final at = rest.substring(0, query);
    if (at == 'relay') {
      if (relay == null) {
        throw const FormatException('the pairing code names no relay');
      }
      return TomSecretsPairingInvitation(
        addresses: const [],
        port: 0,
        code: code,
        relay: relay,
      );
    }
    final colon = at.lastIndexOf(':');
    final port = colon < 0 ? null : int.tryParse(at.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('the pairing code has no port');
    }
    final addresses = <String>[];
    for (final raw in at.substring(0, colon).split(',')) {
      final h = raw.trim();
      final bare = h.startsWith('[') && h.endsWith(']')
          ? h.substring(1, h.length - 1)
          : h;
      if (InternetAddress.tryParse(bare) == null) {
        throw FormatException('not an address: $h');
      }
      addresses.add(bare);
    }
    return TomSecretsPairingInvitation(
      addresses: addresses,
      port: port,
      code: code,
      relay: relay,
    );
  }

  /// The address to connect to from a device with the addresses [own]: one
  /// in the same IPv4 /24 (or IPv6 /64), else the first. Throws
  /// [StateError] for a window on a relay alone (no address).
  String addressFor(List<InternetAddress> own) => addresses.isEmpty
      ? throw StateError('the window waits on a relay only')
      : tomSecretsPairingAddressFor(
          TomSecretsPairingAdvert(
            device: '',
            number: code.number,
            port: port,
            addresses: addresses,
          ),
          own,
        );
}
