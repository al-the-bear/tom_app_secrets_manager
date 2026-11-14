/// The standalone rules on a fixture repository: a path dependency that
/// leaves the repository, a `pubspec_overrides.yaml`, a workspace path in a
/// document; what stays inside the repository passes.
library;

import 'package:test/test.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

void main() {
  test('the three rules, and what passes them', () {
    final root = secretsScratchDir('standalone');
    // Its pubspecs would be analysed with the package.
    addTearDown(() => root.deleteSync(recursive: true));
    secretsWriteFile(root, 'repo/a/pubspec.yaml', '''
name: a
dependencies:
  b:
    path: ../b
  other:
    path: ../../elsewhere/other
  hosted: ^1.0.0
dev_dependencies:
  tool:
    path: ../../tool
''');
    secretsWriteFile(root, 'repo/b/pubspec.yaml', 'name: b\n');
    secretsWriteFile(root, 'repo/b/pubspec_overrides.yaml', 'x: 1\n');
    secretsWriteFile(
      root,
      'repo/README.md',
      'Build it.\nSee _ai/quests/x for the design.\n',
    );
    secretsWriteFile(root, 'repo/doc/ok.md', 'my_ai/ is not a marker\n');
    secretsWriteFile(root, 'repo/a/lib/x.png', '_ai/ in a binary');
    final problems = secretsStandaloneProblems(
      role: 'apps',
      root: '${root.path}/repo',
      files: [
        'a/pubspec.yaml',
        'b/pubspec.yaml',
        'b/pubspec_overrides.yaml',
        'README.md',
        'doc/ok.md',
        'a/lib/x.png',
      ],
    );
    expect(problems.keys, {
      'apps:a/pubspec.yaml',
      'apps:b/pubspec_overrides.yaml',
      'apps:README.md',
    });
    expect(problems['apps:a/pubspec.yaml'], [
      'other (../../elsewhere/other) by path from outside the repository',
      'tool (../../tool) by path from outside the repository',
    ]);
    expect(problems['apps:b/pubspec_overrides.yaml'], [
      'a pubspec_overrides.yaml',
    ]);
    expect(problems['apps:README.md'], [
      'line 2 names the workspace\'s AI state folder',
    ]);
  });

  test('every exception names its todo or its reason', () {
    for (final MapEntry(:key, :value) in secretsStandaloneExceptions.entries) {
      expect(key, matches(RegExp(r'^(apps|secrets_manager|secrets_clients):')));
      expect(value, isNotEmpty);
    }
  });
}
