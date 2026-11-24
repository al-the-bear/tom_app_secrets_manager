// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The Windows passkey plugin's app side (part-os-integration,
/// DP-120): the plugin executable `tsm-passkey-plugin.exe` beside the
/// service, run with `--state`, `--register`, `--unregister` and
/// `--sync-credentials` (the passkeys' names on its standard input, never a
/// key). Windows registers only a packaged plugin: the app's MSIX.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The plugin's file name.
const String tomSecretsPasskeyPluginFile = 'tsm-passkey-plugin.exe';

/// The plugin beside [serviceExecutable].
String tomSecretsPasskeyPluginBeside(String serviceExecutable) {
  final cut = serviceExecutable.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0
      ? tomSecretsPasskeyPluginFile
      : '${serviceExecutable.substring(0, cut + 1)}$tomSecretsPasskeyPluginFile';
}

/// The Windows passkey plugin beside [serviceExecutable], or null off
/// Windows and where this build has no plugin.
TomSecretsWindowsPasskeysPort? tomSecretsDesktopWindowsPasskeys({
  required String serviceExecutable,
  String? operatingSystem,
}) {
  if ((operatingSystem ?? Platform.operatingSystem) != 'windows') return null;
  final plugin = tomSecretsPasskeyPluginBeside(serviceExecutable);
  return File(plugin).existsSync() ? TomSecretsPluginPasskeys(plugin) : null;
}

/// Runs the plugin: [executable] with [arguments], [input] on its standard
/// input; its exit code and output.
typedef TomSecretsPluginRunner =
    Future<({int exitCode, String stdout, String stderr})> Function(
      String executable,
      List<String> arguments,
      String input,
    );

Future<({int exitCode, String stdout, String stderr})> _run(
  String executable,
  List<String> arguments,
  String input,
) async {
  final process = await Process.start(executable, arguments);
  process.stdin.write(input);
  await process.stdin.close();
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode;
  return (exitCode: code, stdout: await out, stderr: await err);
}

/// [TomSecretsWindowsPasskeysPort] over the plugin [executable].
final class TomSecretsPluginPasskeys implements TomSecretsWindowsPasskeysPort {
  /// The port; [run] for a test.
  TomSecretsPluginPasskeys(this.executable, {TomSecretsPluginRunner? run})
    : _runner = run ?? _run;

  /// The plugin executable.
  final String executable;

  final TomSecretsPluginRunner _runner;

  Future<String> _ask(List<String> arguments, [String input = '']) async {
    final r = await _runner(executable, arguments, input);
    if (r.exitCode != 0) {
      final said = r.stderr.trim().replaceFirst(
        RegExp(r'^tsm-passkey-plugin:\s*'),
        '',
      );
      throw TomSecretsWindowsPasskeysException(
        said.isEmpty ? 'The passkey plugin failed (${r.exitCode}).' : said,
      );
    }
    return r.stdout.trim();
  }

  @override
  Future<TomSecretsWindowsPasskeysStatus> status() async =>
      switch (await _ask(const ['--state'])) {
        'enabled' => TomSecretsWindowsPasskeysStatus.enabled,
        'disabled' => TomSecretsWindowsPasskeysStatus.disabled,
        _ => TomSecretsWindowsPasskeysStatus.notRegistered,
      };

  @override
  Future<void> register() => _ask(const ['--register']);

  @override
  Future<void> unregister() => _ask(const ['--unregister']);

  @override
  Future<void> syncCredentials(List<TomSecretsWindowsPasskeyName> names) =>
      _ask(const [
        '--sync-credentials',
      ], names.map((n) => '${n.toLine()}\n').join());
}
