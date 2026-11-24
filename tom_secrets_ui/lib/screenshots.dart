// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The screenshots of the user guides, made by widget tests from demo data
/// (tom_secrets_manager's doc/README.md, "Screenshots"). Not imported by the
/// apps: the screenshot tests of `tom_secrets_ui` (the desktop app's
/// screens) and of `tom_secrets_mobile` use it.
///
/// - **When they run:** a screenshot test is tagged `screenshots` and runs
///   only with `--update-goldens`
///   (`flutter test --tags screenshots --update-goldens`), which writes the
///   PNG files. A normal run (`testkit :test`, `ci.sh :test`) skips it, so
///   a font that renders differently on another machine breaks nothing.
/// - **The real fonts:** a widget test draws text in its square test font;
///   [tomSecretsLoadScreenshotFonts] loads the fonts the screens use
///   instead: Roboto and the Material Icons from the Flutter SDK, and a
///   monospace font of the machine.
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// The test tag of the screenshot tests.
const String tomSecretsScreenshotsTag = 'screenshots';

/// The window sizes of the screenshots, in logical pixels at a device pixel
/// ratio of 1.
abstract final class TomSecretsScreenshotSizes {
  /// The desktop app.
  static const Size desktop = Size(1440, 900);

  /// A phone.
  static const Size phone = Size(390, 844);

  /// A tablet, upright.
  static const Size tablet = Size(1024, 1366);
}

/// The `skip` of a screenshot test: null when the run writes the goldens
/// ([updatingGoldens], flutter_test's `autoUpdateGoldenFiles`, set by
/// `--update-goldens`), else the reason it does not run.
String? tomSecretsScreenshotsSkip(bool updatingGoldens) => updatingGoldens
    ? null
    : 'screenshots are made with --tags $tomSecretsScreenshotsTag '
          '--update-goldens';

/// A screenshot's file name: `<screen>-<state>-<theme>.png`.
String tomSecretsScreenshotName(
  String screen,
  String state,
  Brightness theme,
) => '$screen-$state-${theme == Brightness.dark ? 'dark' : 'light'}.png';

/// The monospace fonts looked for on the machine, in order.
const List<String> tomSecretsMonospaceCandidates = [
  '/System/Library/Fonts/Supplemental/Andale Mono.ttf',
  '/System/Library/Fonts/Supplemental/Courier New.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  r'C:\Windows\Fonts\consola.ttf',
  r'C:\Windows\Fonts\cour.ttf',
];

/// Loads the fonts the screens use: Roboto (every weight the SDK ships) and
/// the Material Icons from the Flutter SDK (`FLUTTER_ROOT`, which
/// `flutter test` sets), and the first monospace font of
/// [tomSecretsMonospaceCandidates] as `monospace`. Throws when the SDK's
/// fonts are not found: a screenshot in the test font is never written.
Future<void> tomSecretsLoadScreenshotFonts({
  Map<String, String>? environment,
}) async {
  final root = (environment ?? Platform.environment)['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) {
    throw StateError('FLUTTER_ROOT is not set: run with flutter test');
  }
  final fonts = Directory(
    '$root/bin/cache/artifacts/material_fonts'.replaceAll(
      '/',
      Platform.pathSeparator,
    ),
  );
  if (!fonts.existsSync()) {
    throw StateError('the Flutter SDK has no material fonts at ${fonts.path}');
  }
  Future<ByteData> read(File file) async =>
      ByteData.sublistView(Uint8List.fromList(await file.readAsBytes()));

  final roboto = FontLoader('Roboto');
  final files = fonts.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    if (name.startsWith('Roboto-') && name.endsWith('.ttf')) {
      roboto.addFont(read(f));
    }
  }
  await roboto.load();

  final icons = FontLoader('MaterialIcons')
    ..addFont(
      read(
        File('${fonts.path}${Platform.pathSeparator}MaterialIcons-Regular.otf'),
      ),
    );
  await icons.load();

  for (final candidate in tomSecretsMonospaceCandidates) {
    final file = File(candidate);
    if (!file.existsSync()) continue;
    await (FontLoader('monospace')..addFont(read(file))).load();
    break;
  }
}
