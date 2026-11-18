// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The pairing invitation of the QR code (DP-56): its text and back, the
/// address nearest the phone, refused texts; the window found on the LAN by
/// the code's number. Demo data only.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

void main() {
  final code = TomSecretsPairingCode(
    17,
    TomSecretsPairingCode.generate().words,
  );
  final c = code.text;

  test('the text and back: IPv4 and IPv6 addresses, the port, the code', () {
    final invitation = TomSecretsPairingInvitation(
      addresses: ['192.168.1.20', 'fd00::2', '10.8.0.2'],
      port: 47900,
      code: code,
    );
    expect(
      invitation.text,
      'tsm-pair:192.168.1.20,[fd00::2],10.8.0.2:47900?code=$c',
    );
    final back = TomSecretsPairingInvitation.parse(invitation.text);
    expect(back.addresses, ['192.168.1.20', 'fd00::2', '10.8.0.2']);
    expect(back.port, 47900);
    expect(back.code.text, c);
  });

  test('the phone connects to the address in its own network', () {
    final invitation = TomSecretsPairingInvitation.parse(
      'tsm-pair:192.168.1.20,10.8.0.2:47900?code=$c',
    );
    expect(invitation.addressFor([InternetAddress('10.8.0.6')]), '10.8.0.2');
    expect(
      invitation.addressFor([InternetAddress('192.168.1.33')]),
      '192.168.1.20',
    );
    expect(invitation.addressFor(const []), '192.168.1.20');
  });

  test('another QR code, or a damaged one, is refused', () {
    for (final text in [
      'otpauth://totp/x?secret=JBSWY3DP',
      'tsm-pair:192.168.1.20:47900',
      'tsm-pair:192.168.1.20?code=$c',
      'tsm-pair:not-an-address:47900?code=$c',
      'tsm-pair:192.168.1.20:70000?code=$c',
      'tsm-pair:192.168.1.20:47900?code=nonsense',
    ]) {
      expect(
        () => TomSecretsPairingInvitation.parse(text),
        throwsFormatException,
        reason: text,
      );
    }
  });

  test('the window on the LAN by its number, near this device', () async {
    final lan = FakePairingDiscovery();
    lan.adverts.add(
      const TomSecretsPairingAdvert(
        device: 'mbp',
        number: 17,
        port: 47900,
        addresses: ['192.168.1.20', 'fd00::2'],
      ),
    );
    final found = await tomSecretsFindPairingWindow(lan, 17, [
      InternetAddress('fd00::9'),
    ]);
    expect(found.typed, '[fd00::2]:47900');
    final none = await tomSecretsFindPairingWindow(lan, 18, const []);
    expect(none.typed, isNull);
    expect(none.problem, contains('No machine on this network'));
    lan.adverts.add(
      const TomSecretsPairingAdvert(
        device: 'bomber',
        number: 17,
        port: 47901,
        addresses: ['192.168.1.21'],
      ),
    );
    final two = await tomSecretsFindPairingWindow(lan, 17, const []);
    expect(two.problem, contains('More than one machine'));
  });

  testWidgets('the QR code is drawn, dark on white', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: TomSecretsQrCode(data: 'tsm-pair:x', size: 120)),
      ),
    );
    expect(find.bySemanticsLabel('QR code'), findsOneWidget);
    expect(tester.getSize(find.byType(TomSecretsQrCode)), const Size(120, 120));
  });
}
