// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// How the two sides of a pairing find each other on the LAN (part-sharing,
/// "How the two sides find each other"): the giving side advertises its open
/// pairing window as an mDNS service `_tsm-pair._tcp`, with the code's
/// number and the window's addresses in the TXT record; the receiving side
/// browses and takes the window whose number the user typed. mDNS does not
/// cross the VPN tunnel: there the receiver types the address.
library;

import 'dart:io';

/// The mDNS service type of an open pairing window.
const String tomSecretsPairingServiceType = '_tsm-pair._tcp';

/// The TXT keys of a pairing window's service.
abstract final class TomSecretsPairingTxt {
  /// The format version (`1`).
  static const String version = 'v';

  /// The code's number.
  static const String number = 'n';

  /// The window's addresses, comma separated.
  static const String addresses = 'a';
}

/// An open pairing window seen on the LAN.
final class TomSecretsPairingAdvert {
  /// A window of [device] with the code number [number], listening on
  /// [port] at [addresses].
  const TomSecretsPairingAdvert({
    required this.device,
    required this.number,
    required this.port,
    required this.addresses,
  });

  /// The giving device's name (the service's name).
  final String device;

  /// The code's number (the part before the words).
  final int number;

  /// The window's port.
  final int port;

  /// The window's addresses (IPv4 or IPv6, as text).
  final List<String> addresses;

  /// The TXT record that announces it.
  Map<String, String> get txt => {
    TomSecretsPairingTxt.version: '1',
    TomSecretsPairingTxt.number: '$number',
    TomSecretsPairingTxt.addresses: addresses.join(','),
  };

  /// The advert of a service named [device] on [port] with [txt], or null
  /// when the record is not a pairing window's (another version, no number,
  /// no address).
  static TomSecretsPairingAdvert? fromTxt({
    required String device,
    required int port,
    required Map<String, String> txt,
    List<String> resolvedAddresses = const [],
  }) {
    if (txt[TomSecretsPairingTxt.version] != '1') return null;
    final number = int.tryParse(txt[TomSecretsPairingTxt.number] ?? '');
    if (number == null || port < 1 || port > 65535) return null;
    final listed = [
      for (final a in (txt[TomSecretsPairingTxt.addresses] ?? '').split(','))
        if (InternetAddress.tryParse(a.trim()) != null) a.trim(),
    ];
    final addresses = listed.isEmpty ? resolvedAddresses : listed;
    if (addresses.isEmpty) return null;
    return TomSecretsPairingAdvert(
      device: device,
      number: number,
      port: port,
      addresses: addresses,
    );
  }
}

/// An advertisement running; [stop] ends it.
abstract interface class TomSecretsPairingAdvertising {
  /// Stops advertising.
  Future<void> stop();
}

/// The host's mDNS (DP-32: the plugin behind a port, implemented in
/// tom_secrets_desktop).
abstract interface class TomSecretsPairingDiscovery {
  /// Advertises [advert] until the answer is stopped.
  Future<TomSecretsPairingAdvertising> advertise(
    TomSecretsPairingAdvert advert,
  );

  /// Browses for [timeout] and answers every pairing window seen.
  Future<List<TomSecretsPairingAdvert>> browse({
    Duration timeout = const Duration(seconds: 4),
  });
}

/// The window among [seen] with the code number [number]: the only one, or
/// null (none, or more than one: then the address is typed).
TomSecretsPairingAdvert? tomSecretsPairingAdvertFor(
  List<TomSecretsPairingAdvert> seen,
  int number,
) {
  final matching = [
    for (final a in seen)
      if (a.number == number) a,
  ];
  return matching.length == 1 ? matching.single : null;
}

/// The address of [advert] to connect to from a machine with the addresses
/// [own]: one in the same IPv4 /24 (or IPv6 /64) as one of [own], else the
/// first. The window takes one connection only, so one address is tried.
String tomSecretsPairingAddressFor(
  TomSecretsPairingAdvert advert,
  List<InternetAddress> own,
) {
  bool near(InternetAddress a, InternetAddress b) {
    if (a.type != b.type) return false;
    final prefix = a.type == InternetAddressType.IPv4 ? 3 : 8;
    for (var i = 0; i < prefix; i++) {
      if (a.rawAddress[i] != b.rawAddress[i]) return false;
    }
    return true;
  }

  for (final text in advert.addresses) {
    final a = InternetAddress.tryParse(text);
    if (a != null && own.any((o) => near(a, o))) return text;
  }
  return advert.addresses.first;
}

/// Where the window with the code number [number] is on the LAN, or why it
/// is not found: browsed through [discovery], the address chosen near
/// [own] (the receiving side's addresses).
Future<TomSecretsPairingFind> tomSecretsFindPairingWindow(
  TomSecretsPairingDiscovery discovery,
  int number,
  List<InternetAddress> own,
) async {
  final seen = await discovery.browse();
  final advert = tomSecretsPairingAdvertFor(seen, number);
  if (advert == null) {
    return TomSecretsPairingFind._(
      problem: seen.any((a) => a.number == number)
          ? 'More than one machine on this network shows a code with '
                '$number: type the address its Pairing screen shows.'
          : 'No machine on this network shows a code with $number. Over '
                'the VPN, or where the network blocks it, type the address '
                'its Pairing screen shows.',
    );
  }
  return TomSecretsPairingFind._(
    address: tomSecretsPairingAddressFor(advert, own),
    port: advert.port,
  );
}

/// What [tomSecretsFindPairingWindow] found.
final class TomSecretsPairingFind {
  const TomSecretsPairingFind._({this.address, this.port, this.problem});

  /// The address to connect to, or null when not found.
  final String? address;

  /// The window's port, or null when not found.
  final int? port;

  /// Why it was not found, for the user, or null.
  final String? problem;

  /// `address:port` as the address field takes it (IPv6 in brackets), or
  /// null.
  String? get typed {
    final a = address;
    if (a == null) return null;
    return a.contains(':') ? '[$a]:$port' : '$a:$port';
  }
}
