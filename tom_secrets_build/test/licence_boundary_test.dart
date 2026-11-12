/// The licence-boundary check over every package of the product's three
/// repositories, as each resolves now: no copyleft licence in any closure,
/// KDBX only through tom_secrets_core (DP-29, DP-203).
///
/// Run by `:licences` after `pub get` in every package; `:test` leaves it out
/// (tag `licence-boundary`), because it reads every package's resolution.
@Tags(['licence-boundary'])
library;

import 'package:test/test.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';

void main() {
  final workspace = SecretsCiWorkspace.find();

  test('the three repositories are checked out', () {
    expect(workspace.missingRepositories(), isEmpty);
  });

  final packages = workspace.discoverPackages();
  test('the product has packages to check', () {
    expect(packages, isNotEmpty);
  });

  // An exception still in force is printed on every run and must still be
  // needed: a package that no longer links the excepted dependency is red.
  for (final pkg in packages) {
    final name = pkg.name.split('/').last;
    for (final MapEntry(key: dependency, value: reason)
        in (secretsLicenceExceptions[name] ?? const <String, String>{})
            .entries) {
      test('${pkg.name} carries $dependency by exception', () {
        print('exception: ${pkg.name} links $dependency — $reason');
        expect(
          secretsLinkedNames(pkg.directory),
          contains(dependency),
          reason: 'the exception is no longer needed: remove it',
        );
      });
    }
  }

  for (final pkg in packages) {
    test(pkg.name, () {
      expect(
        secretsBoundaryProblems(pkg.directory, workspace.repositoryOf(pkg)),
        isEmpty,
      );
    });
  }
}
