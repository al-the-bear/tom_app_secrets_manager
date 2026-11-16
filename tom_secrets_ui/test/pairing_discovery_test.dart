// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Pairing on the LAN (part-sharing): the TXT record of an open pairing
/// window read back, the window chosen by the code's number, the address
/// on this machine's network chosen. Demo data only.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  const advert = TomSecretsPairingAdvert(
    device: 'mbp',
    number: 7,
    port: 47900,
    addresses: ['10.8.0.7', '192.168.1.20', 'fd00::7'],
  );

  test('the TXT record reads back; other records are not windows', () {
    expect(advert.txt, {
      'v': '1',
      'n': '7',
      'a': '10.8.0.7,192.168.1.20,fd00::7',
    });
    final back = TomSecretsPairingAdvert.fromTxt(
      device: 'mbp',
      port: 47900,
      txt: advert.txt,
    )!;
    expect(back.number, 7);
    expect(back.addresses, advert.addresses);
    expect(
      TomSecretsPairingAdvert.fromTxt(
        device: 'x',
        port: 1,
        txt: const {'v': '2', 'n': '7', 'a': '10.0.0.1'},
      ),
      isNull,
      reason: 'another version',
    );
    expect(
      TomSecretsPairingAdvert.fromTxt(
        device: 'x',
        port: 1,
        txt: const {'v': '1', 'a': '10.0.0.1'},
      ),
      isNull,
      reason: 'no number',
    );
    expect(
      TomSecretsPairingAdvert.fromTxt(
        device: 'x',
        port: 1,
        txt: const {'v': '1', 'n': '7', 'a': 'nonsense'},
        resolvedAddresses: const ['192.168.1.5'],
      )!.addresses,
      ['192.168.1.5'],
      reason: 'the resolved addresses when the TXT has none',
    );
  });

  test('the window by the number: one, else none', () {
    const other = TomSecretsPairingAdvert(
      device: 'bomber',
      number: 8,
      port: 1,
      addresses: ['10.8.0.9'],
    );
    expect(tomSecretsPairingAdvertFor([advert, other], 7), same(advert));
    expect(tomSecretsPairingAdvertFor([advert, other], 9), isNull);
    expect(tomSecretsPairingAdvertFor([advert, advert, other], 7), isNull);
  });

  test('the address on this machine\'s network, else the first', () {
    expect(
      tomSecretsPairingAddressFor(advert, [InternetAddress('192.168.1.33')]),
      '192.168.1.20',
    );
    expect(
      tomSecretsPairingAddressFor(advert, [InternetAddress('fd00::9')]),
      'fd00::7',
    );
    expect(
      tomSecretsPairingAddressFor(advert, [InternetAddress('172.16.0.2')]),
      '10.8.0.7',
    );
  });
}
