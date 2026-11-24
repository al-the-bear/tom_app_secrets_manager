// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Attachments shown in the app, in memory only (nothing is written to a
/// file): an image (told by its bytes) in a picture viewer, a text file
/// (`.txt`, `.csv`, `.md`, a PEM key, an `.ovpn` profile, any UTF-8 text) as
/// selectable text, and a binary file offered for saving alone. Demo data
/// only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

/// A 1×1 PNG.
final _png = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGA'
  'WjR9awAAAABJRU5ErkJggg==',
);

void main() {
  group('the kind of an attachment', () {
    Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

    test('images by their bytes, whatever the name', () {
      expect(tomSecretsAttachmentKindOf('photo.png', _png), isImage);
      expect(tomSecretsAttachmentKindOf('no-extension', _png), isImage);
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]);
      expect(tomSecretsAttachmentKindOf('scan.jpg', jpeg), isImage);
      final gif = Uint8List.fromList(utf8.encode('GIF89a......'));
      expect(tomSecretsAttachmentKindOf('a.gif', gif), isImage);
    });

    test('text: UTF-8 without control characters, any name', () {
      for (final name in [
        'notes.txt',
        'list.csv',
        'readme.md',
        'office.ovpn',
        'id_ed25519',
        'key.pem',
      ]) {
        expect(
          tomSecretsAttachmentKindOf(name, text('client\nremote vpn 1194\n')),
          TomSecretsAttachmentKind.text,
          reason: name,
        );
      }
      expect(
        tomSecretsAttachmentKindOf('umlaut.txt', text('Grüße\tTab\r\n')),
        TomSecretsAttachmentKind.text,
      );
      expect(
        tomSecretsAttachmentKindOf('empty.txt', Uint8List(0)),
        TomSecretsAttachmentKind.text,
      );
    });

    test('anything else is a file to save', () {
      expect(
        tomSecretsAttachmentKindOf('x.bin', Uint8List.fromList([0, 1, 2, 3])),
        TomSecretsAttachmentKind.other,
      );
      expect(
        tomSecretsAttachmentKindOf(
          'bad.txt',
          Uint8List.fromList([0x48, 0xC3, 0x28]), // not UTF-8
        ),
        TomSecretsAttachmentKind.other,
      );
    });
  });

  testWidgets('the editor shows an image and a text file; a binary only has '
      'Save', (tester) async {
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Files', password: 'demo-pw')
        ..createBinary(isProtected: false, name: 'photo.png', bytes: _png)
        ..createBinary(
          isProtected: false,
          name: 'office.ovpn',
          bytes: Uint8List.fromList(utf8.encode('client\nremote vpn 1194\n')),
        )
        ..createBinary(
          isProtected: false,
          name: 'blob.bin',
          bytes: Uint8List.fromList([0, 1, 2, 3]),
        );
    });
    final service = FakeService([FakeStore('primary', demoPassword, primary)]);
    final host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
    );
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TomSecretsApp(host: host));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    await tester.tap(find.text('Files'));
    await tester.pump();

    Future<void> view(String name) async {
      final button = find.byKey(Key('tsm-attachment-view-$name'));
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('tsm-entry-editor')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // Fully on screen, not just its first pixels.
      await tester.drag(
        find
            .descendant(
              of: find.byKey(const Key('tsm-entry-editor')),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await view('photo.png');
    expect(find.byKey(const Key('tsm-attachment-image')), findsOneWidget);
    expect(find.text('photo.png'), findsWidgets);
    await tester.tap(find.byKey(const Key('tsm-attachment-close')));
    await tester.pumpAndSettle();

    await view('office.ovpn');
    final shown = tester.widget<SelectableText>(
      find.byKey(const Key('tsm-attachment-text')),
    );
    expect(shown.data, 'client\nremote vpn 1194\n');
    await tester.tap(find.byKey(const Key('tsm-attachment-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tsm-attachment-view-blob.bin')), findsNothing);
  });
}

const isImage = TomSecretsAttachmentKind.image;
