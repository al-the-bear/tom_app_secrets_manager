/// The licence-boundary rules on fixtures: the KDBX gate, and the licence of
/// every package in a resolved closure.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_secrets_build/tom_secrets_build.dart';
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

const _bsd3 =
    'Redistribution and use in source and binary forms, with or without '
    'modification, are permitted. 3. Neither the name of the copyright '
    'holder nor the names of its contributors may be used.';
const _gpl = 'GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007';

void main() {
  group('secretsKdbxProblems', () {
    List<String> check(
      String package, {
      String repository = 'secrets_manager',
      Set<String> declared = const {},
      Set<String> linked = const {},
    }) => secretsKdbxProblems(
      package: package,
      repository: repository,
      declared: declared,
      linked: {package, ...linked},
    );

    test('only tom_secrets_core declares tom_kdbx_store', () {
      expect(
        check(
          'tom_secrets_core',
          declared: {'tom_kdbx_store'},
          linked: {'tom_kdbx_store', 'tom_kpasslib'},
        ),
        isEmpty,
      );
      expect(
        check(
          'tom_secrets_service',
          declared: {'tom_kdbx_store'},
          linked: {'tom_kdbx_store'},
        ),
        [contains('only tom_secrets_core may')],
      );
    });

    test('no package declares a KDBX library itself', () {
      for (final library in secretsKdbxLibraries) {
        expect(check('tom_secrets_core', declared: {library}), [
          contains('declares $library'),
        ], reason: library);
      }
    });

    test('the service and the apps reach KDBX through the core', () {
      expect(
        check(
          'tom_secrets_service',
          declared: {'tom_secrets_core'},
          linked: {'tom_secrets_core', 'tom_kdbx_store', 'tom_kpasslib'},
        ),
        isEmpty,
      );
    });

    test('a client links no KDBX and not the core', () {
      expect(
        check(
          'tsm',
          repository: 'secrets_clients',
          declared: {'tom_secrets_client'},
          linked: {'tom_secrets_client'},
        ),
        isEmpty,
      );
      expect(
        check(
          'tom_secrets_client',
          repository: 'secrets_clients',
          linked: {'tom_secrets_core', 'tom_kdbx_store'},
        ),
        [contains('links tom_secrets_core'), contains('links tom_kdbx_store')],
      );
    });

    test('the relay and the CI link no KDBX either', () {
      for (final package in secretsKdbxFreePackages) {
        expect(
          check(
            package,
            repository: 'app_secrets_manager',
            linked: {'tom_kpasslib'},
          ),
          [contains('links tom_kpasslib')],
          reason: package,
        );
      }
    });
  });

  group('secretsBoundaryProblems', () {
    late Directory root;

    /// A package [name] under [root] with [licence] and [dependencies].
    void package(String name, String? licence, [List<String> deps = const []]) {
      final pubspec = StringBuffer('name: $name\n');
      if (deps.isNotEmpty) {
        pubspec.writeln('dependencies:');
        for (final d in deps) {
          pubspec.writeln('  $d: any');
        }
      }
      secretsWriteFile(root, '$name/pubspec.yaml', pubspec.toString());
      if (licence != null) secretsWriteFile(root, '$name/LICENSE', licence);
    }

    /// The resolution of [start]: every package under [root].
    void resolve(String start, List<String> names) {
      final config = {
        'configVersion': 2,
        'packages': [
          for (final n in names)
            {'name': n, 'rootUri': '../../$n/', 'packageUri': 'lib/'},
        ],
      };
      secretsWriteFile(
        root,
        '$start/.dart_tool/package_config.json',
        jsonEncode(config),
      );
    }

    setUp(() => root = secretsScratchDir('licences'));

    test('a permissive closure passes', () {
      package('tom_secrets_core', _bsd3, ['a', 'tom_kdbx_store']);
      package('a', _bsd3);
      package('tom_kdbx_store', _bsd3);
      resolve('tom_secrets_core', ['tom_secrets_core', 'a', 'tom_kdbx_store']);
      expect(
        secretsBoundaryProblems(
          p.join(root.path, 'tom_secrets_core'),
          'secrets_manager',
        ),
        isEmpty,
      );
    });

    test('a GPL or unlicensed package in the closure is named', () {
      package('tom_secrets_client', _bsd3, ['gpl_pkg', 'bare']);
      package('gpl_pkg', _gpl);
      package('bare', null);
      resolve('tom_secrets_client', ['tom_secrets_client', 'gpl_pkg', 'bare']);
      final problems = secretsBoundaryProblems(
        p.join(root.path, 'tom_secrets_client'),
        'secrets_clients',
      );
      expect(problems, hasLength(2));
      expect(problems, contains(startsWith('gpl_pkg: ')));
      expect(problems, contains(startsWith('bare (')));
    });

    test('a dev dependency is not linked', () {
      package('tom_secrets_build', _bsd3);
      secretsWriteFile(
        root,
        'tom_secrets_build/pubspec.yaml',
        'name: tom_secrets_build\ndev_dependencies:\n  gpl_pkg: any\n',
      );
      package('gpl_pkg', _gpl);
      resolve('tom_secrets_build', ['tom_secrets_build', 'gpl_pkg']);
      expect(
        secretsBoundaryProblems(
          p.join(root.path, 'tom_secrets_build'),
          'app_secrets_manager',
        ),
        isEmpty,
      );
    });

    test('an excepted dependency is left out of the audit, by package', () {
      package('tom_secrets_build', _bsd3, ['ini']);
      package('tom_secrets_ui', _bsd3, ['ini']);
      package('ini', _gpl);
      resolve('tom_secrets_build', ['tom_secrets_build', 'ini']);
      resolve('tom_secrets_ui', ['tom_secrets_ui', 'ini']);
      const exceptions = {
        'tom_secrets_build': {'ini': 'demo exception'},
      };
      expect(
        secretsBoundaryProblems(
          p.join(root.path, 'tom_secrets_build'),
          'app_secrets_manager',
          exceptions: exceptions,
        ),
        isEmpty,
      );
      expect(
        secretsBoundaryProblems(
          p.join(root.path, 'tom_secrets_ui'),
          'app_secrets_manager',
          exceptions: exceptions,
        ),
        [startsWith('ini: ')],
      );
      expect(secretsLinkedNames(p.join(root.path, 'tom_secrets_build')), {
        'tom_secrets_build',
        'ini',
      });
    });

    test('an unresolved package says to run pub get', () {
      package('tom_secrets_ui', _bsd3);
      expect(
        () => secretsBoundaryProblems(
          p.join(root.path, 'tom_secrets_ui'),
          'app_secrets_manager',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('run `pub get`'),
          ),
        ),
      );
    });
  });

  group('secretsNpmProblems', () {
    late Directory root;
    const mit =
        'Permission is hereby granted, free of charge, to any person '
        'obtaining a copy of this software.';

    /// The npm package `pkg` under [root] with [lock]'s `packages`.
    String npmPackage(
      Map<String, Object?> packages, {
      String licence = 'BSD-3-Clause',
      String? licenceFile = _bsd3,
      bool withLock = true,
    }) {
      secretsWriteFile(
        root,
        'pkg/package.json',
        jsonEncode({'name': 'pkg', 'license': licence}),
      );
      if (licenceFile != null) {
        secretsWriteFile(root, 'pkg/LICENSE', licenceFile);
      }
      if (withLock) {
        secretsWriteFile(
          root,
          'pkg/package-lock.json',
          jsonEncode({
            'lockfileVersion': 3,
            'packages': {
              '': {'name': 'pkg'},
              ...packages,
            },
          }),
        );
      }
      return p.join(root.path, 'pkg');
    }

    setUp(() => root = secretsScratchDir('npm'));

    test('dev dependencies are not linked; a permissive closure passes', () {
      final dir = npmPackage({
        'node_modules/typescript': {'dev': true, 'license': 'Apache-2.0'},
        'node_modules/dep': {'license': 'MIT'},
      });
      secretsWriteFile(root, 'pkg/node_modules/dep/LICENSE', mit);
      expect(secretsNpmProblems(dir), isEmpty);
      expect(secretsNpmLinksAnything(dir), isTrue);
    });

    test('a package that links nothing needs no install', () {
      final dir = npmPackage({
        'node_modules/typescript': {'dev': true},
      });
      expect(secretsNpmProblems(dir), isEmpty);
      expect(secretsNpmLinksAnything(dir), isFalse);
    });

    test('a GPL, unlicensed or uninstalled dependency is named, by its '
        'licence file rather than the lock\'s tag', () {
      final dir = npmPackage({
        'node_modules/gpl': {'license': 'MIT'},
        'node_modules/bare': {'license': 'MIT'},
        'node_modules/missing': {'license': 'MIT'},
      });
      secretsWriteFile(root, 'pkg/node_modules/gpl/LICENSE', _gpl);
      secretsWriteFile(root, 'pkg/node_modules/bare/package.json', '{}');
      final problems = secretsNpmProblems(dir);
      expect(problems, hasLength(3));
      expect(
        problems,
        contains(
          'pkg links node_modules/gpl under no recognised licence '
          '(lock: MIT).',
        ),
      );
      expect(problems, contains(startsWith('pkg links node_modules/bare ')));
      expect(problems, contains(contains('run npm ci')));
    });

    test('its own licence is BSD-3, declared and as a file', () {
      final dir = npmPackage(const {}, licence: 'MIT', licenceFile: mit);
      expect(secretsNpmProblems(dir), [
        'pkg declares licence MIT, not BSD-3-Clause.',
        'pkg has no BSD-3 licence file.',
      ]);
    });

    test('no lock: run npm install', () {
      final dir = npmPackage(const {}, withLock: false);
      expect(secretsNpmProblems(dir), [contains('no package-lock.json')]);
      expect(secretsNpmLinksAnything(dir), isFalse);
    });
  });
}
