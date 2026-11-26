/// The stage list and the command surface. The run, the lock, the logs and
/// the summary line are `package:tom_build_base/ci.dart`'s, tested there.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_build_base/ci.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

void main() {
  group('stages', () {
    test('all expands to every stage in order; repeats are dropped', () {
      List<String> resolve(List<String> names) => resolveCiStages(
        names,
        stages: secretsCiStages,
        inAll: (s) => !secretsCiStagesNotInAll.contains(s),
      );
      expect(resolve(['all']), [
        'analyze',
        'test',
        'integration',
        'licences',
        'conformance',
        'standalone',
        'docs',
      ]);
      expect(resolve(['release']), ['release'], reason: 'only when named');
      expect(resolve(['mobile']), ['mobile'], reason: 'only when named');
      expect(resolve(['relay']), ['relay'], reason: 'only when named');
      expect(resolve(['system']), ['system'], reason: 'only when named');
      expect(resolve(['licences', 'analyze', 'licences']), [
        'licences',
        'analyze',
      ]);
      expect(() => resolve(['nope']), throwsArgumentError);
    });

    test('every stage is a command with a description', () {
      for (final stage in [...secretsCiStages, 'all']) {
        expect(
          secretsCiTool.findCommand(stage)?.requiresTraversal,
          isFalse,
          reason: ':$stage',
        );
        expect(secretsCiStageDescriptions[stage], isNotEmpty, reason: stage);
      }
      expect(secretsCiTool.findCommand('lic')?.name, 'licences');
    });

    test('the tool version is the pubspec version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('\nversion: $secretsCiVersion\n'));
    });

    test('the licence-boundary test exists and carries its tag', () {
      final file = File(secretsCiBoundaryTest);
      expect(file.existsSync(), isTrue);
      expect(ciTestTagsOf(Directory.current.path, [secretsCiBoundaryTag]), [
        secretsCiBoundaryTag,
      ]);
      expect(
        File('dart_test.yaml').readAsStringSync(),
        contains('$secretsCiBoundaryTag:'),
      );
    });

    test('a package without test files has no suite, and says why', () {
      final root = secretsScratchDir('no_suite');
      expect(secretsCiNoSuiteReason(root.path), 'no test/ directory');
      secretsWriteFile(root, 'test/helper.dart', '');
      expect(secretsCiNoSuiteReason(root.path), 'no *_test.dart under test/');
      secretsWriteFile(root, 'test/a/b_test.dart', 'void main() {}');
      expect(secretsCiNoSuiteReason(root.path), isNull);
    });
  });

  test(':docs checks the documentation set and every user guide, the '
      'service\'s and the relay\'s operator guides among them', () {
    final workspace = SecretsCiWorkspace(
      repoRoot: '/w/app',
      workspaceRoot: '/w',
      managerRoot: '/w/manager',
      clientsRoot: '/w/clients',
    );
    expect(secretsDocsRoots(workspace), [
      p.join('/w/manager', 'doc'),
      p.join('/w/manager', 'tom_secrets_service', 'doc', 'user_guide.md'),
      p.join('/w/app', 'tom_secrets_relay', 'doc', 'user_guide.md'),
      p.join('/w/app', 'tom_secrets_app', 'doc', 'user_guide.md'),
      p.join('/w/app', 'tom_secrets_mobile', 'doc', 'user_guide.md'),
      p.join('/w/app', 'tom_secrets_browser', 'doc', 'user_guide.md'),
      p.join('/w/app', 'tom_secrets_passkey_plugin', 'doc', 'user_guide.md'),
      p.join('/w/app', 'tom_secrets_build', 'doc', 'user_guide.md'),
      p.join(
        '/w/clients',
        'clients',
        'dart',
        'tsm',
        'doc',
        'tsm_user_guide.md',
      ),
    ]);
  });

  test('the relay image is tagged with the relay\'s version', () {
    expect(secretsRelayImageTag('0.1.0'), 'tom_secrets_relay:0.1.0');
  });

  group('the mobile release', () {
    test('a release is never signed without a complete signing file', () {
      final dir = secretsScratchDir('mobile_signing');
      expect(secretsAndroidSigningProblem(null), contains('is not set'));
      expect(
        secretsAndroidSigningProblem(p.join(dir.path, 'none.properties')),
        contains('no file'),
      );
      final partial = File(
        p.join(dir.path, 'partial.properties'),
      )..writeAsStringSync('storeFile=/k.jks\n# keyAlias=x\nstorePassword=s\n');
      expect(
        secretsAndroidSigningProblem(partial.path),
        endsWith('lacks keyAlias, keyPassword'),
      );
      final full = File(p.join(dir.path, 'full.properties'))
        ..writeAsStringSync(
          'storeFile=/k.jks\nstorePassword=s\nkeyAlias=a\nkeyPassword=k\n',
        );
      expect(secretsAndroidSigningProblem(full.path), isNull);
    });

    test('the browser extension\'s store packages are copied beside the '
        'archives and listed in SHA256SUMS; its version from package.json', () {
      final packages = secretsScratchDir('extension_packages');
      final out = secretsScratchDir('extension_out');
      for (final family in ['chromium', 'firefox']) {
        File(
          p.join(packages.path, secretsExtensionPackageName('0.1.0', family)),
        ).writeAsStringSync(family);
      }
      File(p.join(packages.path, 'notes.txt')).writeAsStringSync('no');
      File(p.join(out.path, 'app.zip')).writeAsStringSync('app');
      // The Mozilla-signed package, put there by hand (tsm_finalize_agent10).
      File(
        p.join(out.path, 'tom-secrets-browser-extension-0.1.0-firefox.xpi'),
      ).writeAsStringSync('signed');
      expect(secretsCopyExtensionPackages(packages.path, out.path), [
        'tom-secrets-browser-extension-0.1.0-chromium.zip',
        'tom-secrets-browser-extension-0.1.0-firefox.zip',
      ]);
      final sums = File(p.join(out.path, 'SHA256SUMS')).readAsLinesSync();
      expect(sums.map((l) => l.split('  ').last), [
        'app.zip',
        'tom-secrets-browser-extension-0.1.0-chromium.zip',
        'tom-secrets-browser-extension-0.1.0-firefox.xpi',
        'tom-secrets-browser-extension-0.1.0-firefox.zip',
      ]);
      expect(File(p.join(out.path, 'notes.txt')).existsSync(), isFalse);
      File(
        p.join(packages.path, 'package.json'),
      ).writeAsStringSync('{"name": "x", "version": "1.2.3"}');
      expect(secretsExtensionVersion(packages.path), '1.2.3');
    });

    test('the APK is named by version and listed in SHA256SUMS', () {
      final dir = secretsScratchDir('mobile_sums');
      File(
        p.join(dir.path, secretsMobileApkName('0.1.0')),
      ).writeAsStringSync('apk');
      File(p.join(dir.path, 'x.zip')).writeAsStringSync('zip');
      File(p.join(dir.path, 'notes.txt')).writeAsStringSync('no');
      secretsWriteSums(dir.path);
      final sums = File(p.join(dir.path, 'SHA256SUMS')).readAsLinesSync();
      expect(sums.map((l) => l.split('  ').last), [
        'tom_secrets_mobile-0.1.0-android.apk',
        'x.zip',
      ]);
    });
  });
}
