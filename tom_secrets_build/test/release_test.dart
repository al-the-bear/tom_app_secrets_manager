/// The release's names and places: platform keys, archive names, where
/// Flutter leaves the app and where the tools sit in the assembled app
/// (`tom_secrets_client`'s distribution layout).
library;

import 'dart:ffi' show Abi;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

void main() {
  test('platform keys and archive names', () {
    expect(secretsReleasePlatform(Abi.macosArm64), 'macos-arm64');
    expect(secretsReleasePlatform(Abi.windowsX64), 'windows-x64');
    expect(secretsReleasePlatform(Abi.linuxX64), 'linux-x64');
    expect(
      secretsAppArchiveName('0.1.0', 'macos-arm64'),
      'tom_secrets_manager-0.1.0-macos-arm64.zip',
    );
    expect(
      secretsToolsArchiveName('0.1.0', 'linux-x64'),
      'tom_secrets_tsm-0.1.0-linux-x64.tar.gz',
    );
  });

  test('where the app is built and where its tools sit', () {
    expect(
      secretsBuiltApp('/a', 'macos-arm64'),
      p.join(
        '/a',
        'build',
        'macos',
        'Build',
        'Products',
        'Release',
        'tom_secrets_app.app',
      ),
    );
    expect(
      secretsBuiltApp('/a', 'linux-x64'),
      p.join('/a', 'build', 'linux', 'x64', 'release', 'bundle'),
    );
    expect(
      secretsBuiltApp('/a', 'windows-x64'),
      p.join('/a', 'build', 'windows', 'x64', 'runner', 'Release'),
    );
    expect(
      secretsBuiltAppExecutable('/x.app', 'macos-arm64'),
      p.join('/x.app', 'Contents', 'MacOS', 'tom_secrets_app'),
    );
    expect(
      secretsBuiltAppExecutable('/r', 'windows-x64'),
      p.join('/r', 'tom_secrets_app.exe'),
    );
    expect(
      secretsAppToolsBin('/r', 'macos-arm64'),
      p.join(
        '/r',
        'stage-macos-arm64',
        'app',
        'Tom Secrets Manager.app',
        'Contents',
        'Resources',
        'tsm',
        'bin',
      ),
    );
    expect(
      secretsAppToolsBin('/r', 'linux-x64'),
      p.join(
        '/r',
        'stage-linux-x64',
        'app',
        'tom_secrets_manager',
        'tsm',
        'bin',
      ),
    );
  });

  test('the version from the pubspec, without a build number', () {
    final root = secretsScratchDir('release');
    secretsWriteFile(root, 'pubspec.yaml', 'name: x\nversion: 1.2.3+4\n');
    expect(secretsPubspecVersion(p.join(root.path, 'pubspec.yaml')), '1.2.3');
  });
}
