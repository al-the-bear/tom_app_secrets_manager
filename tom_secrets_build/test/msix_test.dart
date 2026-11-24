/// The Windows release's MSIX package (part-os-integration, DP-120): the
/// version and architecture MSIX takes, the app's manifest filled in (the
/// passkey plugin as the package's COM server, by the class id the plugin
/// registers), the signing properties, the SDK's tools found. Demo data
/// only.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';

final String _repo = p.dirname(Directory.current.path);

void main() {
  test('the version MSIX takes, and the architecture', () {
    expect(secretsMsixVersion('0.1.0'), '0.1.0.0');
    expect(secretsMsixVersion('1.2.3+4'), '1.2.3.0');
    expect(secretsMsixVersion('1.2.3-dev.1'), '1.2.3.0');
    expect(secretsMsixVersion('2.0'), '2.0.0.0');
    expect(() => secretsMsixVersion('1.x'), throwsFormatException);
    expect(secretsMsixArchitecture('windows-x64'), 'x64');
    expect(secretsMsixArchitecture('windows-arm64'), 'arm64');
    expect(
      secretsMsixName('0.1.0', 'windows-x64'),
      'tom_secrets_manager-0.1.0-windows-x64.msix',
    );
  });

  test('the app\'s manifest: the plugin in tsm\\bin is the package\'s COM '
      'server with the class id the plugin registers; write virtualisation '
      'off', () {
    final packaging = p.join(_repo, 'tom_secrets_app', 'windows', 'packaging');
    final manifest = secretsMsixManifest(
      File(p.join(packaging, 'AppxManifest.xml')).readAsStringSync(),
      version: '0.1.0',
      publisher: 'CN=Tom Secrets Manager Demo & Co',
      architecture: 'x64',
    );
    expect(
      manifest,
      contains('Publisher="CN=Tom Secrets Manager Demo &amp; Co"'),
    );
    expect(manifest, contains('Version="0.1.0.0"'));
    expect(manifest, contains('ProcessorArchitecture="x64"'));
    expect(manifest, contains('Executable="tom_secrets_app.exe"'));
    expect(manifest, contains(r'Executable="tsm\bin\tsm-passkey-plugin.exe"'));
    expect(manifest, contains('Arguments="-PluginActivated"'));
    expect(manifest, contains('<com:Class Id="$secretsPasskeyPluginClassId"'));
    expect(manifest, contains('Name="runFullTrust"'));
    expect(manifest, contains('Name="unvirtualizedResources"'));
    expect(manifest, contains('FileSystemWriteVirtualization>disabled'));
    expect(manifest, contains('RegistryWriteVirtualization>disabled'));
    expect(manifest, isNot(contains('{')));
    for (final asset in RegExp(
      r'Assets\\([\w.]+\.png)',
    ).allMatches(manifest).map((m) => m[1]!)) {
      expect(
        File(p.join(packaging, 'Assets', asset)).existsSync(),
        isTrue,
        reason: asset,
      );
    }
    // The plugin registers the same class id.
    final core = File(
      p.join(_repo, 'tom_secrets_passkey_plugin', 'src', 'core.cpp'),
    ).readAsStringSync();
    expect(core, contains('"$secretsPasskeyPluginClassId"'));
  });

  group('the signing properties', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tsmmsix'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('unset, missing, incomplete and complete', () {
      expect(secretsWindowsSigningProblem(null), contains('is not set'));
      expect(
        secretsWindowsSigningProblem(p.join(dir.path, 'none.properties')),
        contains('no file'),
      );
      final props = File(p.join(dir.path, 'signing.properties'))
        ..writeAsStringSync('# demo\ncertificateFile=${dir.path}/demo.pfx\n');
      expect(
        secretsWindowsSigningProblem(props.path),
        contains('lacks certificatePassword, publisher'),
      );
      props.writeAsStringSync(
        'certificateFile=${dir.path}/demo.pfx\n'
        'certificatePassword=demo-pw\n'
        'publisher=CN=Tom Secrets Manager Demo\n',
      );
      expect(
        secretsWindowsSigningProblem(props.path),
        contains('no certificate'),
      );
      File(p.join(dir.path, 'demo.pfx')).writeAsBytesSync([0]);
      expect(secretsWindowsSigningProblem(props.path), isNull);
      final signing = secretsWindowsSigningOf(props.path);
      expect(signing.publisher, 'CN=Tom Secrets Manager Demo');
      expect(signing.certificatePassword, 'demo-pw');
    });

    test('the newest SDK with the tool', () {
      for (final v in ['10.0.19041.0', '10.0.26100.0', '10.0.22621.0']) {
        Directory(p.join(dir.path, v, 'x64')).createSync(recursive: true);
      }
      File(
        p.join(dir.path, '10.0.19041.0', 'x64', 'makeappx.exe'),
      ).writeAsStringSync('');
      File(
        p.join(dir.path, '10.0.22621.0', 'x64', 'makeappx.exe'),
      ).writeAsStringSync('');
      expect(
        secretsWindowsSdkTool('makeappx.exe', kitsRoot: dir.path),
        p.join(dir.path, '10.0.22621.0', 'x64', 'makeappx.exe'),
      );
      expect(secretsWindowsSdkTool('signtool.exe', kitsRoot: dir.path), isNull);
    });
  });
}
