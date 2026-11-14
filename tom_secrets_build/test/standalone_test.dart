/// The standalone check over the product's three repositories, as they are
/// now: no path dependency into another repository, no
/// `pubspec_overrides.yaml`, no workspace path in code or documents, but the
/// places [secretsStandaloneExceptions] names.
///
/// Run by `:standalone`; `:test` leaves it out (tag `standalone`), because it
/// reads the other two repositories.
@Tags(['standalone'])
library;

import 'package:test/test.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';

void main() {
  final workspace = SecretsCiWorkspace.find();

  test('the three repositories are checked out', () {
    expect(workspace.missingRepositories(), isEmpty);
  });

  final problems = secretsWorkspaceStandaloneProblems(workspace);

  // An exception still in force is printed on every run and must still be
  // needed: a place that follows the rules now is red.
  for (final MapEntry(key: place, value: reason)
      in secretsStandaloneExceptions.entries) {
    test('$place by exception', () {
      print('exception: $place — $reason');
      expect(
        problems.containsKey(place),
        isTrue,
        reason: 'the exception is no longer needed: remove it',
      );
    });
  }

  test('nothing else ties the product to the maintainers\' workspace', () {
    final open = {
      for (final MapEntry(:key, :value) in problems.entries)
        if (!secretsStandaloneExceptions.containsKey(key)) key: value,
    };
    expect(
      open,
      isEmpty,
      reason: [
        for (final MapEntry(:key, :value) in open.entries)
          '$key: ${value.join('; ')}',
      ].join('\n'),
    );
  });
}
