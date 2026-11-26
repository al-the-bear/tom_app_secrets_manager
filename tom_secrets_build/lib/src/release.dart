/// The release of the Tom Secrets Manager for one platform: the manager app
/// carrying `tsm` and the service in its distribution's `tsm` folder
/// (`tom_secrets_client`'s `distribution.dart` names the layout), and `tsm`
/// with the service alone for a server; each an archive, with
/// `SHA256SUMS`, in `tom_secrets_build/release/<version>/`.
///
/// The release stage (`ci.sh :release`) builds the parts and runs
/// `bin/assemble_release.dart`, which calls [secretsAssembleRelease].
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'msix.dart';

/// The name the macOS app bundle has in a release (the Flutter build names
/// it after the package; the executable inside keeps that name).
const String secretsMacAppName = 'Tom Secrets Manager.app';

/// The folder the Windows and Linux app archives unpack into.
const String secretsAppFolderName = 'tom_secrets_manager';

/// The platform key of a release archive for [abi]
/// (`macos-arm64`, `windows-x64`, `linux-x64`, …).
String secretsReleasePlatform([Abi? abi]) {
  final a = abi ?? Abi.current();
  return switch (a) {
    Abi.macosArm64 => 'macos-arm64',
    Abi.macosX64 => 'macos-x64',
    Abi.windowsX64 => 'windows-x64',
    Abi.windowsArm64 => 'windows-arm64',
    Abi.linuxX64 => 'linux-x64',
    Abi.linuxArm64 => 'linux-arm64',
    _ => throw UnsupportedError('no release for $a'),
  };
}

/// The archive extension of [platform]'s releases: `zip` on macOS and
/// Windows, `tar.gz` on Linux.
String secretsArchiveExtension(String platform) =>
    platform.startsWith('linux') ? 'tar.gz' : 'zip';

/// The app archive's file name.
String secretsAppArchiveName(String version, String platform) =>
    'tom_secrets_manager-$version-$platform.${secretsArchiveExtension(platform)}';

/// The tools-only archive's file name.
String secretsToolsArchiveName(String version, String platform) =>
    'tom_secrets_tsm-$version-$platform.${secretsArchiveExtension(platform)}';

/// What the release stage built, for [secretsAssembleRelease].
class SecretsReleaseInputs {
  /// The inputs.
  const SecretsReleaseInputs({
    required this.version,
    required this.platform,
    required this.app,
    required this.serviceBundle,
    required this.tsm,
    required this.browserHost,
    this.passkeyPlugin,
    this.msixPackaging,
    this.windowsSigning,
    required this.licenceFiles,
    this.notices = const {},
    required this.outDir,
  });

  /// From the JSON the stage hands `bin/assemble_release.dart`.
  factory SecretsReleaseInputs.fromJson(Map<String, Object?> json) =>
      SecretsReleaseInputs(
        version: json['version']! as String,
        platform: json['platform']! as String,
        app: json['app']! as String,
        serviceBundle: json['serviceBundle']! as String,
        tsm: json['tsm']! as String,
        browserHost: json['browserHost']! as String,
        passkeyPlugin: json['passkeyPlugin'] as String?,
        msixPackaging: json['msixPackaging'] as String?,
        windowsSigning: json['windowsSigning'] as String?,
        licenceFiles: (json['licenceFiles']! as List).cast<String>(),
        notices: ((json['notices'] as Map?) ?? const {}).cast<String, String>(),
        outDir: json['outDir']! as String,
      );

  /// The release's version (the app's pubspec version).
  final String version;

  /// The platform key ([secretsReleasePlatform]).
  final String platform;

  /// The built app: the `.app` bundle on macOS, the folder holding the
  /// executable on Windows and Linux.
  final String app;

  /// The service's `dart build cli` bundle (`bin/`, `lib/`).
  final String serviceBundle;

  /// The `tsm` executable (`dart compile exe`).
  final String tsm;

  /// The browser host `tsm-browser-host` (`dart compile exe`), beside the
  /// service where it recognises it (protocol.md 5.5).
  final String browserHost;

  /// **[C]** Windows: the passkey plugin `tsm-passkey-plugin.exe` (CMake),
  /// beside the service in the app's tools folder (part-os-integration,
  /// DP-120); null elsewhere.
  final String? passkeyPlugin;

  /// **[C]** Windows: the folder with the MSIX manifest template and its
  /// assets (`tom_secrets_app/windows/packaging`); with [windowsSigning]
  /// the app is also packed as a signed MSIX. Null elsewhere.
  final String? msixPackaging;

  /// **[C]** Windows: the signing properties file
  /// ([secretsWindowsSigningVariable]).
  final String? windowsSigning;

  /// Files every archive carries (`LICENSE`, `THIRD_PARTY.md`).
  final List<String> licenceFiles;

  /// The licence texts of bundled third-party code every archive carries in
  /// its `licenses/` folder, by the file name they get there.
  final Map<String, String> notices;

  /// Where the archives go.
  final String outDir;

  /// The JSON for `bin/assemble_release.dart`.
  Map<String, Object?> toJson() => {
    'version': version,
    'platform': platform,
    'app': app,
    'serviceBundle': serviceBundle,
    'tsm': tsm,
    'browserHost': browserHost,
    'passkeyPlugin': ?passkeyPlugin,
    'msixPackaging': ?msixPackaging,
    'windowsSigning': ?windowsSigning,
    'licenceFiles': licenceFiles,
    'notices': notices,
    'outDir': outDir,
  };
}

/// What [secretsAssembleRelease] made.
class SecretsRelease {
  /// The release.
  const SecretsRelease({
    required this.appArchive,
    required this.toolsArchive,
    required this.appDistribution,
    required this.toolsDistribution,
    this.msix,
  });

  /// The app archive.
  final String appArchive;

  /// The tools-only archive.
  final String toolsArchive;

  /// The assembled app (the `.app` on macOS, the folder elsewhere), kept
  /// beside the archives for a smoke run.
  final String appDistribution;

  /// The assembled tools folder of the tools-only archive (`bin/`, `lib/`).
  final String toolsDistribution;

  /// **[C]** The signed MSIX package (Windows), or null.
  final String? msix;
}

/// Assembles the release of [inputs]: the app with `tsm` and the service in
/// its tools folder (on macOS ad-hoc signed again, inner code first), the
/// tools alone, both archived, and `SHA256SUMS` over the archives. Writes
/// into `outDir`, replacing a release of the same version and platform.
Future<SecretsRelease> secretsAssembleRelease(
  SecretsReleaseInputs inputs, {
  void Function(String line)? log,
}) async {
  final say = log ?? (_) {};
  final mac = inputs.platform.startsWith('macos');
  final windows = inputs.platform.startsWith('windows');
  final exe = windows ? '.exe' : '';
  final stage = Directory(p.join(inputs.outDir, 'stage-${inputs.platform}'));
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);

  // The app, with its tools folder.
  final appDist = mac
      ? p.join(stage.path, 'app', secretsMacAppName)
      : p.join(stage.path, 'app', secretsAppFolderName);
  await _copyTree(inputs.app, appDist);
  final appTools = mac
      ? p.join(appDist, 'Contents', 'Resources', 'tsm')
      : p.join(appDist, 'tsm');
  final docsDir = mac ? p.join(appDist, 'Contents', 'Resources') : appDist;

  // The tools alone.
  final toolsName = 'tom_secrets_tsm-${inputs.version}-${inputs.platform}';
  final toolsDist = p.join(stage.path, 'tools', toolsName);

  for (final tools in [appTools, toolsDist]) {
    await _copyTree(p.join(inputs.serviceBundle, 'bin'), p.join(tools, 'bin'));
    final lib = p.join(inputs.serviceBundle, 'lib');
    if (Directory(lib).existsSync()) {
      await _copyTree(lib, p.join(tools, 'lib'));
    }
    final tsmTarget = p.join(tools, 'bin', 'tsm$exe');
    File(inputs.tsm).copySync(tsmTarget);
    final hostTarget = p.join(tools, 'bin', 'tsm-browser-host$exe');
    File(inputs.browserHost).copySync(hostTarget);
    if (!windows) {
      await _run('chmod', ['755', tsmTarget]);
      await _run('chmod', ['755', hostTarget]);
    }
  }
  // The passkey plugin serves the app's package only: the tools alone are
  // for a server.
  if (inputs.passkeyPlugin case final plugin?) {
    File(plugin).copySync(p.join(appTools, 'bin', p.basename(plugin)));
  }
  for (final f in inputs.licenceFiles) {
    File(f).copySync(p.join(docsDir, p.basename(f)));
    File(f).copySync(p.join(toolsDist, p.basename(f)));
  }
  for (final MapEntry(key: name, value: source) in inputs.notices.entries) {
    for (final dir in [docsDir, toolsDist]) {
      Directory(p.join(dir, 'licenses')).createSync(recursive: true);
      File(source).copySync(p.join(dir, 'licenses', name));
    }
  }
  say('assembled ${p.relative(appDist, from: inputs.outDir)} and $toolsName');

  if (mac) {
    // Adding files to the bundle broke its seal: sign the inner code, then
    // the bundle (ad-hoc, `-`), as the Flutter build did.
    for (final tools in [appTools, toolsDist]) {
      for (final f in [
        ...Directory(p.join(tools, 'bin')).listSync(),
        if (Directory(p.join(tools, 'lib')).existsSync())
          ...Directory(p.join(tools, 'lib')).listSync(),
      ]) {
        if (f is File) await _run('codesign', ['--force', '-s', '-', f.path]);
      }
    }
    await _run('codesign', ['--force', '-s', '-', appDist]);
    await _run('codesign', ['--verify', '--strict', appDist]);
    say('signed (ad-hoc) and verified $secretsMacAppName');
  }

  final appArchive = p.join(
    inputs.outDir,
    secretsAppArchiveName(inputs.version, inputs.platform),
  );
  final toolsArchive = p.join(
    inputs.outDir,
    secretsToolsArchiveName(inputs.version, inputs.platform),
  );
  await _archive(p.dirname(appDist), p.basename(appDist), appArchive);
  await _archive(p.dirname(toolsDist), toolsName, toolsArchive);
  String? msix;
  if (windows &&
      inputs.msixPackaging != null &&
      inputs.windowsSigning != null) {
    msix = await secretsPackMsix(
      appDistribution: appDist,
      packagingDir: inputs.msixPackaging!,
      layoutDir: p.join(stage.path, 'msix'),
      version: inputs.version,
      platform: inputs.platform,
      signing: secretsWindowsSigningOf(inputs.windowsSigning!),
      outDir: inputs.outDir,
    );
    say('packed and signed ${p.basename(msix)}');
  }
  _writeSums(inputs.outDir);
  say(
    'wrote ${p.basename(appArchive)}, ${p.basename(toolsArchive)}, SHA256SUMS',
  );
  return SecretsRelease(
    appArchive: appArchive,
    toolsArchive: toolsArchive,
    appDistribution: appDist,
    toolsDistribution: toolsDist,
    msix: msix,
  );
}

/// Copies the tree [from] to [to] (created), keeping symbolic links and
/// modes on macOS and Linux (`ditto`, `cp -a`).
Future<void> _copyTree(String from, String to) async {
  Directory(p.dirname(to)).createSync(recursive: true);
  if (Platform.isMacOS) {
    await _run('ditto', [from, to]);
  } else if (Platform.isLinux) {
    await _run('cp', ['-a', from, to]);
  } else {
    for (final e in Directory(from).listSync(recursive: true)) {
      final target = p.join(to, p.relative(e.path, from: from));
      if (e is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (e is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        e.copySync(target);
      }
    }
  }
}

/// Archives [name] in [dir] as [archive]: a zip (macOS `ditto`, which keeps
/// the bundle's links and attributes; Windows `tar -a`) or a gzip tarball.
Future<void> _archive(String dir, String name, String archive) async {
  final file = File(archive);
  if (file.existsSync()) file.deleteSync();
  if (archive.endsWith('.tar.gz')) {
    await _run('tar', ['-czf', archive, '-C', dir, name]);
  } else if (Platform.isMacOS) {
    await _run('ditto', [
      '-c',
      '-k',
      '--keepParent',
      p.join(dir, name),
      archive,
    ]);
  } else {
    await _run('tar', ['-a', '-cf', archive, '-C', dir, name]);
  }
}

/// The Android app's file in a release (DP-204: installed directly).
String secretsMobileApkName(String version) =>
    'tom_secrets_mobile-$version-android.apk';

/// The browser extension's version, from its `package.json` in
/// [extensionDir].
String secretsExtensionVersion(String extensionDir) {
  final json = jsonDecode(
    File(p.join(extensionDir, 'package.json')).readAsStringSync(),
  );
  final version = json is Map ? json['version'] : null;
  if (version is! String) {
    throw FormatException('no version in $extensionDir/package.json');
  }
  return version;
}

/// The store package of the browser extension at [version] for [family]
/// (`chromium`, `firefox`), as `npm run build` names it.
String secretsExtensionPackageName(String version, String family) =>
    'tom-secrets-browser-extension-$version-$family.zip';

/// The browser extension's store packages: one ZIP per browser family
/// (`npm run build` in `tom_secrets_browser/extension`).
bool secretsIsExtensionPackage(String name) =>
    name.startsWith('tom-secrets-browser-extension-') && name.endsWith('.zip');

/// Copies the extension's store packages of [packagesDir] into [outDir] and
/// writes its `SHA256SUMS` again; answers the names copied.
List<String> secretsCopyExtensionPackages(String packagesDir, String outDir) {
  final names = <String>[];
  for (final f in Directory(packagesDir).listSync().whereType<File>()) {
    final name = p.basename(f.path);
    if (!secretsIsExtensionPackage(name)) continue;
    f.copySync(p.join(outDir, name));
    names.add(name);
  }
  secretsWriteSums(outDir);
  return names..sort();
}

/// Writes `SHA256SUMS` over every archive, APK, MSIX package and signed
/// Firefox package (`.xpi`) in [outDir].
void secretsWriteSums(String outDir) => _writeSums(outDir);

void _writeSums(String outDir) {
  final lines = <String>[];
  final archives =
      Directory(outDir)
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.endsWith('.zip') ||
                f.path.endsWith('.tar.gz') ||
                f.path.endsWith('.apk') ||
                f.path.endsWith('.msix') ||
                f.path.endsWith('.xpi'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in archives) {
    final digest = crypto.sha256.convert(f.readAsBytesSync());
    lines.add('$digest  ${p.basename(f.path)}');
  }
  File(p.join(outDir, 'SHA256SUMS')).writeAsStringSync('${lines.join('\n')}\n');
}

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    throw ProcessException(
      exe,
      args,
      '${r.stdout}${r.stderr}'.trim(),
      r.exitCode,
    );
  }
}

/// The version in the pubspec at [pubspecPath] (`version:` up to a `+`).
String secretsPubspecVersion(String pubspecPath) {
  final line = LineSplitter.split(
    File(pubspecPath).readAsStringSync(),
  ).firstWhere((l) => l.startsWith('version:'));
  return line.substring('version:'.length).trim().split('+').first;
}

/// Runs `tsm` of the release in [toolsBin] against the demo installation
/// [installation] (`data/bootstrap.yaml`, its `runtime_dir`): `start
/// --unlock` with [password] on standard input, `status --json`, `stop`.
/// True when the service started from beside `tsm`, unlocked (its native
/// library loaded: the unlock creates the device's hybrid keys) and
/// stopped.
Future<bool> secretsSmokeRelease({
  required String toolsBin,
  required String installation,
  required String password,
  void Function(String line)? log,
}) async {
  final say = log ?? (_) {};
  final tsm = p.join(toolsBin, Platform.isWindows ? 'tsm.exe' : 'tsm');
  final env = {
    'TSM_DATA_DIR': p.join(installation, 'data'),
    'TSM_RUNTIME_DIR': p.join(installation, 'run'),
    // tsm's pins of the demo service stay with the demo installation.
    'TSM_CONFIG_DIR': p.join(installation, 'config'),
  };
  Future<ProcessResult> run(List<String> args, {String? stdinText}) async {
    final process = await Process.start(tsm, args, environment: env);
    if (stdinText != null) process.stdin.writeln(stdinText);
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    final result = ProcessResult(process.pid, code, await out, await err);
    say('tsm ${args.join(' ')} -> $code');
    if ('${result.stdout}'.trim().isNotEmpty) say('${result.stdout}'.trim());
    if ('${result.stderr}'.trim().isNotEmpty) say('${result.stderr}'.trim());
    return result;
  }

  final started = await run([
    '--password-stdin',
    'start',
    '--unlock',
  ], stdinText: password);
  if (started.exitCode != 0) return false;
  // The admin key of this start is in the keychain where there is one; a
  // session without it (an SSH logon on Windows, a Linux without a keyring)
  // claims again with the master password, read only then.
  try {
    final status = await run([
      '--password-stdin',
      'status',
      '--json',
    ], stdinText: password);
    if (status.exitCode != 0) return false;
    final report = jsonDecode('${status.stdout}');
    final locked = report is Map ? report['locked'] : null;
    if (locked != false) {
      say('the service is not unlocked: $report');
      return false;
    }
    return true;
  } finally {
    await run(['--password-stdin', 'stop'], stdinText: password);
  }
}

/// The `bin` folder of the tools inside the assembled app of [platform]
/// under [outDir] (the stage folder [secretsAssembleRelease] keeps).
String secretsAppToolsBin(String outDir, String platform) {
  final app = p.join(outDir, 'stage-$platform', 'app');
  return platform.startsWith('macos')
      ? p.join(app, secretsMacAppName, 'Contents', 'Resources', 'tsm', 'bin')
      : p.join(app, secretsAppFolderName, 'tsm', 'bin');
}

/// Where `flutter build <platform> --release` leaves the app of the package
/// at [appPackage]: the `.app` bundle on macOS, the folder holding the
/// executable on Windows and Linux.
String secretsBuiltApp(String appPackage, String platform) {
  final arch = platform.endsWith('arm64') ? 'arm64' : 'x64';
  if (platform.startsWith('macos')) {
    return p.join(
      appPackage,
      'build',
      'macos',
      'Build',
      'Products',
      'Release',
      'tom_secrets_app.app',
    );
  }
  if (platform.startsWith('windows')) {
    return p.join(appPackage, 'build', 'windows', arch, 'runner', 'Release');
  }
  return p.join(appPackage, 'build', 'linux', arch, 'release', 'bundle');
}

/// The licence texts of the native code `tom_pqc` vendors, as the package
/// [packageDir] resolves `tom_pqc`, by the name they get in a release's
/// `licenses/` folder; empty when it does not reach `tom_pqc`.
Map<String, String> secretsPqcNotices(String packageDir) {
  final config = File(p.join(packageDir, '.dart_tool', 'package_config.json'));
  if (!config.existsSync()) return const {};
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  final pqc = packages.cast<Map>().where((e) => e['name'] == 'tom_pqc');
  if (pqc.isEmpty) return const {};
  final root = Directory.fromUri(
    config.uri.resolve(pqc.first['rootUri'] as String),
  ).path;
  return {
    for (final vendored in ['mlkem-native', 'mldsa-native'])
      if (File(p.join(root, 'native', vendored, 'LICENSE')).existsSync())
        'LICENSE.$vendored': p.join(root, 'native', vendored, 'LICENSE'),
    if (File(p.join(root, 'LICENSE')).existsSync())
      'LICENSE.tom_pqc': p.join(root, 'LICENSE'),
  };
}

/// The executable inside the app [secretsBuiltApp] names: what its build
/// must leave behind.
String secretsBuiltAppExecutable(String builtApp, String platform) {
  if (platform.startsWith('macos')) {
    return p.join(builtApp, 'Contents', 'MacOS', 'tom_secrets_app');
  }
  return p.join(
    builtApp,
    platform.startsWith('windows') ? 'tom_secrets_app.exe' : 'tom_secrets_app',
  );
}
