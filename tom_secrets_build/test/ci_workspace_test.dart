/// Package and manifest discovery over the three repositories.
library;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

void main() {
  group('SecretsCiWorkspace', () {
    late SecretsCiWorkspace workspace;

    setUp(() {
      final root = secretsScratchDir('workspace');
      void pubspec(String dir) =>
          secretsWriteFile(root, '$dir/pubspec.yaml', 'name: x\n');
      secretsWriteFile(root, 'app_secrets_manager/tom_repository.yaml', '');
      pubspec('app_secrets_manager/tom_secrets_build');
      pubspec('app_secrets_manager/tom_secrets_app');
      pubspec('app_secrets_manager/tom_secrets_app/example');
      pubspec('app_secrets_manager/tom_secrets_app/test/fixture');
      pubspec('app_secrets_manager/tom_secrets_app/.dart_tool/x');
      pubspec('app_secrets_manager/tom_secrets_app/build/y');
      secretsWriteFile(
        root,
        'app_secrets_manager/tom_secrets_app/android/build.gradle',
        '',
      );
      secretsWriteFile(
        root,
        'app_secrets_manager/tom_secrets_browser/package.json',
        '{}',
      );
      secretsWriteFile(
        root,
        'app_secrets_manager/tom_secrets_browser/node_modules/a/package.json',
        '{}',
      );
      secretsWriteFile(
        root,
        'app_secrets_manager/tools/stdlib_only/go.mod',
        'module example.com/a\n\ngo 1.27\n',
      );
      secretsWriteFile(
        root,
        'app_secrets_manager/tools/with_deps/go.mod',
        'module example.com/b\n\ngo 1.27\n\n'
            'require golang.org/x/crypto v0.59.0\n',
      );
      secretsWriteFile(root, 'tom_ai/secrets_manager/tom_repository.yaml', '');
      pubspec('tom_ai/secrets_manager/tom_secrets_core');
      pubspec('tom_ai/secrets_manager/a/b/c/d/too_deep');
      workspace = SecretsCiWorkspace.find(
        from: p.join(root.path, 'app_secrets_manager', 'tom_secrets_build'),
        workspaceRoot: root.path,
      );
    });

    test('finds this repository and names the three repositories', () {
      expect(p.basename(workspace.repoRoot), 'app_secrets_manager');
      expect(workspace.repositories, [
        'app_secrets_manager',
        'tom_ai/secrets_manager',
        'tom_ai/secrets_clients',
      ]);
      expect(workspace.missingRepositories(), ['tom_ai/secrets_clients']);
    });

    test('finds the packages, not examples, fixtures, build output or '
        'what is too deep', () {
      final names = [for (final pkg in workspace.discoverPackages()) pkg.name];
      expect(names, [
        'app_secrets_manager/tom_secrets_app',
        'app_secrets_manager/tom_secrets_build',
        'tom_ai/secrets_manager/tom_secrets_core',
      ]);
      final core = workspace.discoverPackages().last;
      expect(workspace.repositoryOf(core), 'tom_ai/secrets_manager');
    });

    test(
      'finds foreign manifests outside node_modules and platform folders',
      () {
        expect(workspace.foreignManifests(), [
          'app_secrets_manager/tom_secrets_browser/package.json',
          'app_secrets_manager/tools/stdlib_only/go.mod',
          'app_secrets_manager/tools/with_deps/go.mod',
        ]);
      },
    );

    test('a Go module that requires nothing is checked, one with '
        'requirements is not', () {
      expect(workspace.uncheckedForeignManifests(), [
        'app_secrets_manager/tom_secrets_browser/package.json',
        'app_secrets_manager/tools/with_deps/go.mod',
      ]);
    });
  });

  group('secretsGoModuleRequirements', () {
    test('reads require lines and blocks, indirect ones too', () {
      expect(
        secretsGoModuleRequirements('''
module example.com/x

go 1.27

require golang.org/x/crypto v0.59.0 // a comment

require (
\tgolang.org/x/sys v0.50.0 // indirect

\texample.com/y v1.0.0
)
'''),
        [
          'golang.org/x/crypto v0.59.0',
          'golang.org/x/sys v0.50.0',
          'example.com/y v1.0.0',
        ],
      );
    });

    test('a module without require has none', () {
      expect(secretsGoModuleRequirements('module m\n\ngo 1.27\n'), isEmpty);
    });
  });
}
