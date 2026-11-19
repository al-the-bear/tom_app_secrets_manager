/// The stages of the Tom Secrets Manager's CI and what each does. The run
/// around them — the lock, the logs, the summary line — is
/// `package:tom_build_base/ci.dart`'s.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_build_base/ci.dart';

import 'ci_workspace.dart';
import 'licence_boundary.dart';
import 'release.dart';

/// The stages, in the order `:all` runs them. The build stages of the desktop
/// app join when `tom_secrets_app` exists.
const List<String> secretsCiStages = [
  'analyze',
  'test',
  'integration',
  'licences',
  'conformance',
  'standalone',
  'release',
  'mobile',
];

/// The stages `:all` leaves out: the releases are built when one is made.
const Set<String> secretsCiStagesNotInAll = {'release', 'mobile'};

/// One-line descriptions, shared by `--help` and the README.
const Map<String, String> secretsCiStageDescriptions = {
  'analyze':
      'pub get + analyze (infos fatal) in every package of the three '
      'repositories; npm ci + npm run build in every npm package; '
      'cargo clippy in every Cargo package; javac (lint, warnings fatal) in '
      'every Maven project that links only the JDK; go vet in every Go '
      'module that '
      'requires nothing; compileall in every '
      'Python package; on macOS '
      'the AutoFill provider\'s extension target compiled (unsigned)',
  'test':
      'every package suite, strictly serial, one full log per package '
      '(the licence-boundary check is :licences\', the integration suites '
      ':integration\'); npm test in every npm package; cargo test in every '
      'Cargo package; the AllTests of every such Maven project; go test in '
      'every Go '
      'module with tests; unittest in every Python package; on macOS swift '
      'test '
      'of the AutoFill provider\'s core',
  'integration':
      'the integration suites against the real service (test tag '
      'integration): the service built as a binary, started and driven by '
      'tsm and the Dart client',
  'licences':
      'pub get in every package, then the licence-boundary check: no '
      'copyleft licence in any closure, KDBX only through tom_secrets_core; '
      'the npm and Cargo closures from their locks; Maven and Python '
      'projects that link nothing beyond their platform; every other non-Dart manifest is '
      'red until its closure is checked',
  'conformance':
      'the client conformance suite (tom_secrets_clients/conformance): the '
      'reference table current, the coverage gate, every runner against every '
      'case table, a runner without its toolchain red',
  'standalone':
      'the standalone check over the three repositories\' tracked files: no '
      'path dependency into another repository, no pubspec_overrides.yaml, no '
      'path of the maintainers\' workspace in code or documents, but the '
      'exceptions on record',
  'release':
      'the release for this platform (not part of :all): the service bundle, '
      'tsm, the browser host, the app built with them in its tsm folder, the app and tools-only '
      'archives and the browser extension\'s store packages with SHA256SUMS in '
      'tom_secrets_build/release/<version>/, and '
      'a smoke run of the assembled tsm and service on a demo installation',
  'mobile':
      'the mobile app\'s Android release (not part of :all): the APK signed '
      'with the key TSM_ANDROID_SIGNING names, as '
      'tom_secrets_mobile-<version>-android.apk beside the release archives, '
      'in SHA256SUMS; iOS is installed from Xcode (DP-130)',
  'all':
      'every stage above but :release and :mobile, in that order, continuing '
      'past a red',
};

/// The test tag of the licence-boundary check, run by `:licences` only.
const String secretsCiBoundaryTag = 'licence-boundary';

/// The test tag of the integration suites, run by `:integration` only.
const String secretsCiIntegrationTag = 'integration';

/// The test tag of the standalone check, run by `:standalone` only.
const String secretsCiStandaloneTag = 'standalone';

/// The standalone test `:standalone` runs in this package.
const String secretsCiStandaloneTest = 'test/standalone_test.dart';

/// The licence-boundary test `:licences` runs in this package.
const String secretsCiBoundaryTest = 'test/licence_boundary_test.dart';

/// The run of [stages] for [workspace], its logs in
/// `tom_secrets_build/testlog/<timestamp>/`.
CiRun secretsCiRun({
  required SecretsCiWorkspace workspace,
  required StringSink console,
}) => CiRun(
  toolName: 'tom_secrets_build',
  repositoryRoot: workspace.repoRoot,
  lockPath: workspace.flutterLockPath(),
  logRoot: p.join(workspace.buildPackageDir, 'testlog'),
  stageDescriptions: secretsCiStageDescriptions,
  console: console,
  runStage: SecretsCiStages(workspace).run,
);

/// What each of [secretsCiStages] does, over [workspace].
class SecretsCiStages {
  SecretsCiStages(this.workspace);

  final SecretsCiWorkspace workspace;

  /// Runs [stage] as steps of [run].
  Future<void> run(CiRun run, String stage) async {
    for (final missing in workspace.missingRepositories()) {
      run.fail(
        stage,
        missing,
        '$stage.missing.${missing.replaceAll('/', '.')}.log',
        'repository $missing is not checked out under '
            '${workspace.workspaceRoot}',
      );
    }
    final packages = workspace.discoverPackages();
    switch (stage) {
      case 'analyze':
        for (final pkg in packages) {
          await run.step(stage, pkg.name, 'analyze.${pkg.logName}.log', [
            run.tool(pkg, ['pub', 'get']),
            pkg.isFlutter
                ? run.tool(pkg, ['analyze'])
                : run.tool(pkg, ['analyze', '--fatal-infos']),
          ], needsFlutter: pkg.isFlutter);
        }
        for (final dir in workspace.npmPackageDirs()) {
          final name = workspace.relative(dir);
          await run.step(stage, name, 'analyze.${_npmLogName(name)}.log', [
            _npm(['ci'], dir),
            // tsc with the package's strict settings is its analyzer.
            _npm(['run', 'build'], dir),
          ]);
        }
        for (final dir in workspace.cargoPackageDirs()) {
          final name = workspace.relative(dir);
          // clippy with every feature, warnings fatal, is the analyzer.
          await run.step(stage, name, 'analyze.${_cargoLogName(name)}.log', [
            _cargo(const [
              'clippy',
              '--all-features',
              '--all-targets',
              '--locked',
              '--',
              '-D',
              'warnings',
            ], dir),
          ]);
        }
        for (final dir in workspace.javaPackageDirs()) {
          final name = workspace.relative(dir);
          // javac with every lint, warnings fatal, at the release the pom
          // names, is the analyzer.
          await run.step(stage, name, 'analyze.${_javaLogName(name)}.log', [
            _javac(dir, const ['src/main/java'], 'classes'),
          ]);
        }
        for (final dir in workspace.goModuleDirs()) {
          final name = workspace.relative(dir);
          await run.step(stage, name, 'analyze.${_goLogName(name)}.log', [
            CiCommand('go', const ['vet', './...'], workingDirectory: dir),
          ]);
        }
        for (final dir in workspace.pythonPackageDirs()) {
          final name = workspace.relative(dir);
          // Byte-compiling every module is the syntax check; the package
          // uses the standard library only, so there is nothing to install.
          await run.step(stage, name, 'analyze.${_pythonLogName(name)}.log', [
            _python(['-m', 'compileall', '-q', 'src', 'tests'], dir),
          ]);
        }
        if (Platform.isMacOS) await _autofillBuild(run, stage);
      case 'test':
        for (final pkg in packages) {
          final noSuite = secretsCiNoSuiteReason(pkg.directory);
          if (noSuite != null) {
            run.skip(stage, pkg.name, '${pkg.logName}.log', noSuite);
            continue;
          }
          final excluded = ciTestTagsOf(pkg.directory, const [
            secretsCiBoundaryTag,
            secretsCiIntegrationTag,
            secretsCiStandaloneTag,
          ]);
          await run.step(
            stage,
            pkg.name,
            '${pkg.logName}.log',
            [
              run.tool(pkg, [
                'test',
                if (excluded.isNotEmpty) ...[
                  '--exclude-tags',
                  excluded.join(','),
                ],
              ]),
            ],
            needsFlutter: pkg.isFlutter,
            counts: true,
          );
        }
        for (final dir in workspace.npmPackageDirs()) {
          final name = workspace.relative(dir);
          await run.step(stage, name, '${_npmLogName(name)}.log', [
            _npm(['ci'], dir),
            _npm(['test'], dir),
          ]);
        }
        for (final dir in workspace.cargoPackageDirs()) {
          final name = workspace.relative(dir);
          await run.step(stage, name, '${_cargoLogName(name)}.log', [
            _cargo(const ['test', '--all-features', '--locked'], dir),
          ]);
        }
        for (final dir in workspace.javaPackageDirs()) {
          final name = workspace.relative(dir);
          final main = secretsJavaTestMain(dir);
          if (main == null) {
            run.skip(stage, name, '${_javaLogName(name)}.log', 'no AllTests');
            continue;
          }
          await run.step(stage, name, '${_javaLogName(name)}.log', [
            _javac(dir, const [
              'src/main/java',
              'src/test/java',
            ], 'test-classes'),
            CiCommand('java', [
              '-cp',
              p.join('build', 'ci', 'test-classes'),
              main,
            ], workingDirectory: dir),
          ]);
        }
        for (final dir in workspace.goModuleDirs()) {
          final name = workspace.relative(dir);
          // A module without _test.go files (a tool run with go run) has
          // no suite; go test would only report that.
          final hasTests = Directory(dir)
              .listSync(recursive: true)
              .any((e) => e is File && e.path.endsWith('_test.go'));
          if (!hasTests) {
            run.skip(stage, name, '${_goLogName(name)}.log', 'no _test.go');
            continue;
          }
          await run.step(stage, name, '${_goLogName(name)}.log', [
            CiCommand('go', const [
              'test',
              '-count=1',
              './...',
            ], workingDirectory: dir),
          ]);
        }
        for (final dir in workspace.pythonPackageDirs()) {
          final name = workspace.relative(dir);
          if (!Directory(p.join(dir, 'tests')).existsSync()) {
            run.skip(stage, name, '${_pythonLogName(name)}.log', 'no tests/');
            continue;
          }
          await run.step(stage, name, '${_pythonLogName(name)}.log', [
            _python(
              ['-m', 'unittest', 'discover', '-s', 'tests', '-v'],
              dir,
              environment: {'PYTHONPATH': 'src'},
            ),
          ]);
        }
        if (Platform.isMacOS) {
          // The AutoFill provider's core (DP-50): CryptoKit and XCTest.
          final kit = p.join(_appMacos, 'TomSecretsAutofillKit');
          await run.step(stage, workspace.relative(kit), 'autofill_kit.log', [
            CiCommand('swift', const ['test'], workingDirectory: kit),
          ]);
        }
      case 'integration':
        for (final pkg in packages) {
          if (ciTestTagsOf(pkg.directory, const [
            secretsCiIntegrationTag,
          ]).isEmpty) {
            continue;
          }
          await run.step(
            stage,
            pkg.name,
            'integration.${pkg.logName}.log',
            [
              run.tool(pkg, ['test', '--tags', secretsCiIntegrationTag]),
            ],
            needsFlutter: pkg.isFlutter,
            counts: true,
          );
        }
      case 'licences':
        for (final manifest in workspace.uncheckedForeignManifests()) {
          run.fail(
            stage,
            manifest,
            'licences.manifest.${manifest.replaceAll('/', '.')}.log',
            p.basename(manifest) == 'package.json'
                ? 'no package-lock.json beside it: the npm closure check '
                      'reads the lock — run npm install and commit it'
                : p.basename(manifest) == 'pom.xml'
                ? 'it links dependencies: only a Maven project whose '
                      'dependencies are all test-scoped (the JDK its closure) '
                      'is checked'
                : p.basename(manifest) == 'Cargo.toml'
                ? 'no Cargo.lock beside it: the Cargo closure check reads '
                      'the lock — run cargo generate-lockfile and commit it'
                : p.basename(manifest) == 'pyproject.toml'
                ? 'it declares requirements: only a Python project that '
                      'requires nothing (the standard library its closure) '
                      'is checked'
                : 'no closure check reads '
                      '${secretsCiForeignManifests[p.basename(manifest)]} '
                      'manifests yet — add one to the licence-boundary check',
          );
        }
        await run.step(stage, 'pub get', 'licences.pub-get.log', [
          for (final pkg in packages) run.tool(pkg, ['pub', 'get']),
        ], needsFlutter: packages.any((pkg) => pkg.isFlutter));
        final build = CiPackage(
          name: 'tom_secrets_build',
          directory: workspace.buildPackageDir,
          isFlutter: false,
        );
        for (final dir in workspace.npmPackageDirs()) {
          // The closure is classified by its installed licence files; a
          // package that links nothing needs no install (and no npm).
          if (!secretsNpmLinksAnything(dir)) continue;
          final name = workspace.relative(dir);
          await run.step(
            stage,
            '$name npm ci',
            'licences.npm-ci.${_npmLogName(name)}.log',
            [
              _npm(['ci', '--omit=dev'], dir),
            ],
          );
        }
        for (final dir in workspace.cargoPackageDirs()) {
          // The check reads every linked crate's manifest and licence
          // files: fetched from the lock first.
          final name = workspace.relative(dir);
          await run.step(
            stage,
            '$name cargo fetch',
            'licences.cargo-fetch.${_cargoLogName(name)}.log',
            [
              _cargo(const ['fetch', '--locked'], dir),
            ],
          );
        }
        await run.step(stage, 'licence boundary', 'licences.boundary.log', [
          run.tool(build, [
            'test',
            '--tags',
            secretsCiBoundaryTag,
            secretsCiBoundaryTest,
          ]),
        ], counts: true);
      case 'conformance':
        final clients = workspace.clientsRoot;
        await run.step(stage, 'conformance', 'conformance.log', [
          CiCommand(
            Platform.isWindows ? 'py' : 'python3',
            [
              if (Platform.isWindows) '-3',
              p.join('conformance', 'tool', 'conformance.py'),
              'all',
            ],
            workingDirectory: clients,
            // The suite builds the fake service and the runners with the
            // same dart the other stages use.
            environment: {
              if (p.isAbsolute(run.dart))
                'PATH':
                    '${p.dirname(run.dart)}'
                    '${Platform.isWindows ? ';' : ':'}'
                    '${Platform.environment['PATH'] ?? ''}',
            },
          ),
        ]);
      case 'standalone':
        await run.step(stage, 'standalone', 'standalone.log', [
          run.tool(_buildPackage, ['pub', 'get']),
          run.tool(_buildPackage, [
            'test',
            '--tags',
            secretsCiStandaloneTag,
            secretsCiStandaloneTest,
          ]),
        ], counts: true);
      case 'release':
        await _release(run);
      case 'mobile':
        await _mobile(run);
      default:
        throw ArgumentError.value(stage, 'stage', 'not a stage');
    }
  }
}

extension on SecretsCiStages {
  CiPackage get _buildPackage => CiPackage(
    name: 'tom_secrets_build',
    directory: workspace.buildPackageDir,
    isFlutter: false,
  );

  /// The app's macOS folder (the Xcode project, the AutoFill provider).
  String get _appMacos =>
      p.join(workspace.repoRoot, 'tom_secrets_app', 'macos');

  /// The macOS AutoFill provider's extension target compiled, unsigned
  /// (its entitlements need the team; the team-signed build embeds it):
  /// Flutter's generated Swift package first, which the Xcode project
  /// resolves.
  Future<void> _autofillBuild(CiRun run, String stage) async {
    final app = CiPackage(
      name: workspace.relative(p.join(workspace.repoRoot, 'tom_secrets_app')),
      directory: p.join(workspace.repoRoot, 'tom_secrets_app'),
      isFlutter: true,
    );
    final out = p.join(app.directory, 'build', 'autofill');
    await run.step(
      stage,
      'TomSecretsAutofill (macOS AutoFill provider)',
      'analyze.autofill.log',
      [
        run.tool(app, ['build', 'macos', '--config-only']),
        CiCommand('xcodebuild', [
          '-project',
          'Runner.xcodeproj',
          '-target',
          'TomSecretsAutofill',
          '-configuration',
          'Release',
          'CODE_SIGNING_ALLOWED=NO',
          'SYMROOT=$out',
          'build',
        ], workingDirectory: _appMacos),
      ],
      needsFlutter: true,
      produces: p.join(
        out,
        'Release',
        'TomSecretsAutofill.appex',
        'Contents',
        'Info.plist',
      ),
    );
  }

  /// The mobile app's Android release: the signed APK beside the archives.
  Future<void> _mobile(CiRun run) async {
    const stage = 'mobile';
    final mobile = p.join(workspace.repoRoot, 'tom_secrets_mobile');
    final version = secretsPubspecVersion(p.join(mobile, 'pubspec.yaml'));
    final signing = Platform.environment[secretsAndroidSigningVariable];
    final problem = secretsAndroidSigningProblem(signing);
    if (problem != null) {
      run.fail(stage, 'signing', 'mobile.signing.log', problem);
      return;
    }
    final app = CiPackage(
      name: workspace.relative(mobile),
      directory: mobile,
      isFlutter: true,
    );
    final built = p.join(
      mobile,
      'build',
      'app',
      'outputs',
      'flutter-apk',
      'app-release.apk',
    );
    await run.step(
      stage,
      'apk',
      'mobile.apk.log',
      [
        run.tool(app, ['pub', 'get']),
        run.tool(app, ['build', 'apk', '--release']),
      ],
      needsFlutter: true,
      produces: built,
    );
    if (!File(built).existsSync()) return;
    final outDir = p.join(workspace.buildPackageDir, 'release', version);
    Directory(outDir).createSync(recursive: true);
    File(built).copySync(p.join(outDir, secretsMobileApkName(version)));
    secretsWriteSums(outDir);
  }

  /// The release for this platform: the parts, the assembly, a smoke run.
  Future<void> _release(CiRun run) async {
    const stage = 'release';
    final platform = secretsReleasePlatform();
    final windows = platform.startsWith('windows');
    final exe = windows ? '.exe' : '';
    final appPackage = p.join(workspace.repoRoot, 'tom_secrets_app');
    final version = secretsPubspecVersion(p.join(appPackage, 'pubspec.yaml'));
    final releaseRoot = p.join(workspace.buildPackageDir, 'release');
    final outDir = p.join(releaseRoot, version);
    final work = p.join(releaseRoot, 'work-$platform');
    Directory(outDir).createSync(recursive: true);
    Directory(work).createSync(recursive: true);

    CiPackage package(String dir, {bool flutter = false}) => CiPackage(
      name: workspace.relative(dir),
      directory: dir,
      isFlutter: flutter,
    );

    final service = package(
      p.join(workspace.managerRoot, 'tom_secrets_service'),
    );
    final serviceBundle = p.join(work, 'service', 'bundle');
    await run.step(stage, 'service', 'release.service.log', [
      run.tool(service, ['pub', 'get']),
      run.tool(service, [
        'build',
        'cli',
        '--target',
        'bin/tom_secrets_service.dart',
        '-o',
        p.join(work, 'service'),
      ]),
    ], produces: p.join(serviceBundle, 'bin', 'tom_secrets_service$exe'));

    final tsmPackage = package(
      p.join(workspace.clientsRoot, 'clients', 'dart', 'tsm'),
    );
    final tsm = p.join(work, 'tsm', 'tsm$exe');
    Directory(p.dirname(tsm)).createSync(recursive: true);
    await run.step(stage, 'tsm', 'release.tsm.log', [
      run.tool(tsmPackage, ['pub', 'get']),
      run.tool(tsmPackage, ['compile', 'exe', 'bin/tsm.dart', '-o', tsm]),
    ], produces: tsm);

    final browserPackage = package(
      p.join(workspace.repoRoot, 'tom_secrets_browser'),
    );
    final browserHost = p.join(work, 'browser', 'tsm-browser-host$exe');
    Directory(p.dirname(browserHost)).createSync(recursive: true);
    await run.step(stage, 'browser host', 'release.browser_host.log', [
      run.tool(browserPackage, ['pub', 'get']),
      run.tool(browserPackage, [
        'compile',
        'exe',
        'bin/tsm_browser_host.dart',
        '-o',
        browserHost,
      ]),
    ], produces: browserHost);

    // The browser extension's store packages (the same on every platform):
    // the Chromium ZIP and the Firefox ZIP Mozilla signs (part-browser,
    // DP-204), beside the archives.
    final extension = p.join(
      workspace.repoRoot,
      'tom_secrets_browser',
      'extension',
    );
    final extensionPackages = p.join(extension, 'dist', 'packages');
    await run.step(
      stage,
      'browser extension',
      'release.browser_extension.log',
      [
        _npm(['ci'], extension),
        _npm(['run', 'build'], extension),
      ],
      produces: p.join(
        extensionPackages,
        secretsExtensionPackageName(
          secretsExtensionVersion(extension),
          'chromium',
        ),
      ),
    );

    final app = package(appPackage, flutter: true);
    final built = secretsBuiltApp(appPackage, platform);
    await run.step(
      stage,
      'app',
      'release.app.log',
      [
        run.tool(app, ['pub', 'get']),
        run.tool(app, ['build', platform.split('-').first, '--release']),
      ],
      needsFlutter: true,
      produces: secretsBuiltAppExecutable(built, platform),
    );

    final inputs = SecretsReleaseInputs(
      version: version,
      platform: platform,
      app: built,
      serviceBundle: serviceBundle,
      tsm: tsm,
      browserHost: browserHost,
      licenceFiles: [
        p.join(workspace.repoRoot, 'LICENSE'),
        p.join(workspace.repoRoot, 'THIRD_PARTY.md'),
      ],
      notices: secretsPqcNotices(service.directory),
      outDir: outDir,
    );
    final inputsFile = File(p.join(work, 'inputs.json'))
      ..writeAsStringSync(jsonEncode(inputs.toJson()));
    await run.step(stage, 'assemble', 'release.assemble.log', [
      run.tool(_buildPackage, [
        'run',
        'bin/assemble_release.dart',
        inputsFile.path,
      ]),
    ], produces: p.join(outDir, secretsAppArchiveName(version, platform)));
    if (Directory(extensionPackages).existsSync()) {
      secretsCopyExtensionPackages(extensionPackages, outDir);
    }

    // The smoke run's installation is in the system's temporary folder: a
    // Unix socket path is limited to 104 bytes on macOS, which a path in the
    // repository exceeds (as for the service's own tests).
    final demo = Directory.systemTemp.createTempSync('tsmrel');
    try {
      final desktop = package(
        p.join(workspace.repoRoot, 'tom_secrets_desktop'),
      );
      await run.step(stage, 'smoke', 'release.smoke.log', [
        run.tool(desktop, ['run', 'tool/demo_installation.dart', demo.path]),
        run.tool(_buildPackage, [
          'run',
          'bin/smoke_release.dart',
          secretsAppToolsBin(outDir, platform),
          demo.path,
          secretsReleaseSmokePassword,
        ]),
      ]);
    } finally {
      demo.deleteSync(recursive: true);
    }
  }
}

/// The environment variable naming the Android signing properties file
/// (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`), read by the
/// mobile app's Gradle build.
const String secretsAndroidSigningVariable = 'TSM_ANDROID_SIGNING';

/// Why [path] (the variable's value) cannot sign a release, or null.
String? secretsAndroidSigningProblem(String? path) {
  if (path == null || path.isEmpty) {
    return '$secretsAndroidSigningVariable is not set: name the signing '
        'properties file (storeFile, storePassword, keyAlias, keyPassword); '
        'a release is never signed with the debug key';
  }
  final file = File(path);
  if (!file.existsSync()) {
    return '$secretsAndroidSigningVariable: no file $path';
  }
  final keys = {
    for (final line in file.readAsLinesSync())
      if (line.contains('=') && !line.trimLeft().startsWith('#'))
        line.substring(0, line.indexOf('=')).trim(),
  };
  final missing = [
    for (final k in const [
      'storeFile',
      'storePassword',
      'keyAlias',
      'keyPassword',
    ])
      if (!keys.contains(k)) k,
  ];
  return missing.isEmpty
      ? null
      : '$secretsAndroidSigningVariable: $path lacks ${missing.join(', ')}';
}

/// The demo master password of the smoke run's installation (the desktop
/// package's `tool/demo_installation.dart`; demo data only).
const String secretsReleaseSmokePassword = 'primary-demo-pw';

/// An npm command in [dir] (on Windows through the shell, as every CI
/// command, which finds `npm.cmd`).
CiCommand _npm(List<String> args, String dir) =>
    CiCommand('npm', args, workingDirectory: dir);

String _npmLogName(String name) => 'npm.${name.replaceAll('/', '.')}';

/// A Python 3 command in [dir]: `py -3` on Windows (the launcher, where
/// `python3` is often missing), `python3` elsewhere.
CiCommand _python(
  List<String> args,
  String dir, {
  Map<String, String> environment = const {},
}) => CiCommand(
  Platform.isWindows ? 'py' : 'python3',
  [if (Platform.isWindows) '-3', ...args],
  workingDirectory: dir,
  environment: environment,
);

/// The class of a Java project's tests: `src/test/java/**/AllTests.java`
/// as a class name (its tests are a plain main class), or null when it has
/// none.
String? secretsJavaTestMain(String projectDir) {
  final root = Directory(p.join(projectDir, 'src', 'test', 'java'));
  if (!root.existsSync()) return null;
  for (final entry in root.listSync(recursive: true)) {
    if (entry is File && p.basename(entry.path) == 'AllTests.java') {
      return p
          .withoutExtension(p.relative(entry.path, from: root.path))
          .replaceAll(RegExp(r'[/\\]'), '.');
    }
  }
  return null;
}

/// The release a Maven project compiles for (`maven.compiler.release`),
/// else 16 (the client's `UnixDomainSocketAddress`).
String secretsJavaRelease(String projectDir) {
  final pom = File(p.join(projectDir, 'pom.xml'));
  final release = pom.existsSync()
      ? RegExp(
          r'<maven\.compiler\.release>\s*(\d+)\s*</maven\.compiler\.release>',
        ).firstMatch(pom.readAsStringSync())?.group(1)
      : null;
  return release ?? '16';
}

/// javac over every `.java` file under [sources] (relative to [dir]) into
/// `build/ci/<out>`, with every lint and warnings fatal.
CiCommand _javac(String dir, List<String> sources, String out) {
  final files = <String>[
    for (final source in sources)
      if (Directory(p.join(dir, source)).existsSync())
        for (final entry in Directory(
          p.join(dir, source),
        ).listSync(recursive: true))
          if (entry is File && entry.path.endsWith('.java'))
            p.relative(entry.path, from: dir),
  ]..sort();
  return CiCommand('javac', [
    '--release',
    secretsJavaRelease(dir),
    '-Xlint:all',
    '-Werror',
    '-d',
    p.join('build', 'ci', out),
    ...files,
  ], workingDirectory: dir);
}

String _javaLogName(String name) => 'java.${name.replaceAll('/', '.')}';

/// A cargo command in [dir].
CiCommand _cargo(List<String> args, String dir) =>
    CiCommand('cargo', args, workingDirectory: dir);

String _cargoLogName(String name) => 'cargo.${name.replaceAll('/', '.')}';

String _goLogName(String name) => 'go.${name.replaceAll('/', '.')}';

String _pythonLogName(String name) => 'python.${name.replaceAll('/', '.')}';

/// Why [packageDir] has no suite to run, or null when it has one: no
/// `test/` directory, or no `*_test.dart` in it.
String? secretsCiNoSuiteReason(String packageDir) {
  final dir = Directory(p.join(packageDir, 'test'));
  if (!dir.existsSync()) return 'no test/ directory';
  final hasTest = dir
      .listSync(recursive: true)
      .any((e) => e is File && e.path.endsWith('_test.dart'));
  return hasTest ? null : 'no *_test.dart under test/';
}
