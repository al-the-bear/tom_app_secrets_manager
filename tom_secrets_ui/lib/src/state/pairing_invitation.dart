// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The pairing invitation (DP-56, DP-61): what the giving desktop's QR code
/// carries — the addresses its pairing window listens on, its port and the
/// one-time code — as one line of text,
///
///     tsm-pair:<address>[,<address>…]:<port>?code=<code>
///
/// an IPv6 address in brackets (`tsm-pair:[fd00::2],10.8.0.2:47900?code=…`).
/// The phone scans it and connects to the address nearest its own, as it
/// does with a window found on the LAN; typing the address and code is the
/// fallback. The code works once, so the text is no secret once used, but a
/// photo of an open window's QR code is as good as the typed code.
library;

import 'dart:io';

import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsPairingCode;

import '../ports/pairing_discovery.dart';

/// The scheme of the invitation text.
const String tomSecretsPairingScheme = 'tsm-pair';

/// An open pairing window, as its QR code tells it.
final class TomSecretsPairingInvitation {
  /// The window at [addresses] (at least one) on [port] with [code].
  TomSecretsPairingInvitation({
    required List<String> addresses,
    required this.port,
    required this.code,
  }) : addresses = List.unmodifiable(addresses) {
    if (this.addresses.isEmpty) {
      throw ArgumentError.value(addresses, 'addresses', 'empty');
    }
  }

  /// The addresses the window listens on (IPv4 or IPv6, as text).
  final List<String> addresses;

  /// The window's port.
  final int port;

  /// The one-time code.
  final TomSecretsPairingCode code;

  /// The text of the QR code.
  String get text {
    final hosts = [
      for (final a in addresses) a.contains(':') ? '[$a]' : a,
    ].join(',');
    return '$tomSecretsPairingScheme:$hosts:$port?code=${code.text}';
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
    final at = rest.substring(0, query);
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
    );
  }

  /// The address to connect to from a device with the addresses [own]: one
  /// in the same IPv4 /24 (or IPv6 /64), else the first.
  String addressFor(List<InternetAddress> own) => tomSecretsPairingAddressFor(
    TomSecretsPairingAdvert(
      device: '',
      number: code.number,
      port: port,
      addresses: addresses,
    ),
    own,
  );
}
