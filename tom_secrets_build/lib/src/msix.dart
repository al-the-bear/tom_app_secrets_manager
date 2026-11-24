/// The Windows release's MSIX package (part-os-integration, DP-120): the
/// assembled app with its tools folder, the package manifest of
/// `tom_secrets_app/windows/packaging/` filled in, signed with the
/// certificate `TSM_WINDOWS_SIGNING` names. Windows registers the passkey
/// plugin only from a package (the manifest names it as the package's COM
/// server).
///
/// The certificate is a self-signed code-signing certificate for now: each
/// machine trusts it once it is in its Trusted People store
/// (`windows/new_signing_certificate.ps1` makes it,
/// `windows/install_signing_certificate.ps1` installs it, as an
/// administrator).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The environment variable naming the Windows signing properties file
/// (`certificateFile`, a PKCS#12 `.pfx`; `certificatePassword`;
/// `publisher`, the certificate's subject, e.g. `CN=Tom Secrets Manager`).
const String secretsWindowsSigningVariable = 'TSM_WINDOWS_SIGNING';

/// The passkey plugin's COM class id (the plugin's `pluginClassId`).
const String secretsPasskeyPluginClassId =
    'c7185d2d-97da-4fd3-bec2-f615368a5ecf';

/// The MSIX package's file name in a release.
String secretsMsixName(String version, String platform) =>
    'tom_secrets_manager-$version-$platform.msix';

/// [version] as MSIX takes it: four numbers (`0.1.0` → `0.1.0.0`), any
/// pre-release or build suffix dropped.
String secretsMsixVersion(String version) {
  final parts = version.split(RegExp(r'[-+]')).first.split('.');
  if (parts.length > 4 || parts.any((n) => int.tryParse(n) == null)) {
    throw FormatException('not a package version: $version');
  }
  return [...parts, ...List.filled(4 - parts.length, '0')].join('.');
}

/// The package architecture of [platform] (`windows-x64` → `x64`).
String secretsMsixArchitecture(String platform) =>
    platform.endsWith('arm64') ? 'arm64' : 'x64';

/// The package manifest [template] filled in.
String secretsMsixManifest(
  String template, {
  required String version,
  required String publisher,
  required String architecture,
}) => template
    .replaceAll('{publisher}', _xml(publisher))
    .replaceAll('{version}', secretsMsixVersion(version))
    .replaceAll('{architecture}', architecture)
    .replaceAll('{plugin_class_id}', secretsPasskeyPluginClassId);

String _xml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The signing certificate a properties file names.
final class SecretsWindowsSigning {
  /// The certificate [certificateFile] under [certificatePassword], its
  /// subject [publisher].
  const SecretsWindowsSigning({
    required this.certificateFile,
    required this.certificatePassword,
    required this.publisher,
  });

  /// The PKCS#12 file.
  final String certificateFile;

  /// Its password.
  final String certificatePassword;

  /// Its subject, the package's publisher.
  final String publisher;
}

/// Why the properties file [path] (the variable's value) cannot sign a
/// package, or null.
String? secretsWindowsSigningProblem(String? path) {
  if (path == null || path.isEmpty) {
    return '$secretsWindowsSigningVariable is not set: name the signing '
        'properties file (certificateFile, certificatePassword, publisher; '
        'windows/new_signing_certificate.ps1 writes one); the MSIX package '
        'is never unsigned';
  }
  if (!File(path).existsSync()) {
    return '$secretsWindowsSigningVariable: no file $path';
  }
  final values = _properties(path);
  final missing = [
    for (final k in const [
      'certificateFile',
      'certificatePassword',
      'publisher',
    ])
      if ((values[k] ?? '').isEmpty) k,
  ];
  if (missing.isNotEmpty) {
    return '$secretsWindowsSigningVariable: $path lacks ${missing.join(', ')}';
  }
  if (!File(values['certificateFile']!).existsSync()) {
    return '$secretsWindowsSigningVariable: no certificate '
        '${values['certificateFile']}';
  }
  return null;
}

/// The signing certificate of the properties file [path]
/// ([secretsWindowsSigningProblem] null).
SecretsWindowsSigning secretsWindowsSigningOf(String path) {
  final values = _properties(path);
  return SecretsWindowsSigning(
    certificateFile: values['certificateFile']!,
    certificatePassword: values['certificatePassword']!,
    publisher: values['publisher']!,
  );
}

Map<String, String> _properties(String path) => {
  for (final line in File(path).readAsLinesSync())
    if (line.contains('=') && !line.trimLeft().startsWith('#'))
      line.substring(0, line.indexOf('=')).trim(): line
          .substring(line.indexOf('=') + 1)
          .trim(),
};

/// The Windows SDK's [tool] (`makeappx.exe`, `signtool.exe`) of the newest
/// SDK that has it, for [architecture]'s host; null without one.
String? secretsWindowsSdkTool(
  String tool, {
  String? kitsRoot,
  String architecture = 'x64',
}) {
  final bin = Directory(
    kitsRoot ??
        p.join(
          Platform.environment['ProgramFiles(x86)'] ??
              r'C:\Program Files (x86)',
          'Windows Kits',
          '10',
          'bin',
        ),
  );
  if (!bin.existsSync()) return null;
  final versions =
      bin
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .where((n) => RegExp(r'^10\.\d+\.\d+\.\d+$').hasMatch(n))
          .toList()
        ..sort(_compareVersions);
  for (final v in versions.reversed) {
    final candidate = p.join(bin.path, v, architecture, tool);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

int _compareVersions(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 4; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

/// Packs [appDistribution] (the assembled app, its tools folder with the
/// passkey plugin) with the manifest and assets of [packagingDir] into
/// [outDir]/[secretsMsixName] and signs it with [signing]; answers the
/// package's path. [layoutDir] is the package's layout, replaced.
Future<String> secretsPackMsix({
  required String appDistribution,
  required String packagingDir,
  required String layoutDir,
  required String version,
  required String platform,
  required SecretsWindowsSigning signing,
  required String outDir,
}) async {
  final makeappx = secretsWindowsSdkTool('makeappx.exe');
  final signtool = secretsWindowsSdkTool('signtool.exe');
  if (makeappx == null || signtool == null) {
    throw StateError(
      'the Windows SDK (makeappx.exe, signtool.exe) is not installed',
    );
  }
  final layout = Directory(layoutDir);
  if (layout.existsSync()) layout.deleteSync(recursive: true);
  _copyTree(Directory(appDistribution), layout);
  _copyTree(
    Directory(p.join(packagingDir, 'Assets')),
    Directory(p.join(layout.path, 'Assets')),
  );
  File(p.join(layout.path, 'AppxManifest.xml')).writeAsStringSync(
    secretsMsixManifest(
      File(p.join(packagingDir, 'AppxManifest.xml')).readAsStringSync(),
      version: version,
      publisher: signing.publisher,
      architecture: secretsMsixArchitecture(platform),
    ),
  );
  final package = p.join(outDir, secretsMsixName(version, platform));
  await _run(makeappx, ['pack', '/o', '/d', layout.path, '/p', package]);
  await _run(signtool, [
    'sign',
    '/fd',
    'SHA256',
    '/f',
    signing.certificateFile,
    '/p',
    signing.certificatePassword,
    package,
  ]);
  return package;
}

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync(recursive: true)) {
    final target = p.join(to.path, p.relative(e.path, from: from.path));
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      e.copySync(target);
    }
  }
}

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    // The password is never repeated in a failure.
    throw ProcessException(
      p.basename(exe),
      [args.first],
      '${r.stdout}${r.stderr}'.trim(),
      r.exitCode,
    );
  }
}
