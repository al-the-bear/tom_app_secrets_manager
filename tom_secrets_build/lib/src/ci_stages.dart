/// The stages of the Tom Secrets Manager's CI and what each does. The run
/// around them — the lock, the logs, the summary line — is
/// `package:tom_build_base/ci.dart`'s.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_build_base/ci.dart';

import 'ci_workspace.dart';

/// The stages, in the order `:all` runs them. The build stages of the desktop
/// app join when `tom_secrets_app` exists.
const List<String> secretsCiStages = ['analyze', 'test', 'licences'];

/// One-line descriptions, shared by `--help` and the README.
const Map<String, String> secretsCiStageDescriptions = {
  'analyze':
      'pub get + analyze (infos fatal) in every package of the three '
      'repositories',
  'test':
      'every package suite, strictly serial, one full log per package '
      '(the licence-boundary check is :licences\')',
  'licences':
      'pub get in every package, then the licence-boundary check: no '
      'copyleft licence in any closure, KDBX only through tom_secrets_core; '
      'every non-Dart manifest is red until its closure is checked',
  'all': 'every stage above, in that order, continuing past a red',
};

/// The test tag of the licence-boundary check, run by `:licences` only.
const String secretsCiBoundaryTag = 'licence-boundary';

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
      case 'test':
        for (final pkg in packages) {
          final noSuite = secretsCiNoSuiteReason(pkg.directory);
          if (noSuite != null) {
            run.skip(stage, pkg.name, '${pkg.logName}.log', noSuite);
            continue;
          }
          await run.step(
            stage,
            pkg.name,
            '${pkg.logName}.log',
            [
              run.tool(pkg, [
                'test',
                if (ciTestTagsOf(pkg.directory, const [
                  secretsCiBoundaryTag,
                ]).isNotEmpty) ...[
                  '--exclude-tags',
                  secretsCiBoundaryTag,
                ],
              ]),
            ],
            needsFlutter: pkg.isFlutter,
            counts: true,
          );
        }
      case 'licences':
        for (final manifest in workspace.foreignManifests()) {
          run.fail(
            stage,
            manifest,
            'licences.manifest.${manifest.replaceAll('/', '.')}.log',
            'no closure check reads ${secretsCiForeignManifests[p.basename(manifest)]} '
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
        await run.step(stage, 'licence boundary', 'licences.boundary.log', [
          run.tool(build, [
            'test',
            '--tags',
            secretsCiBoundaryTag,
            secretsCiBoundaryTest,
          ]),
        ], counts: true);
      default:
        throw ArgumentError.value(stage, 'stage', 'not a stage');
    }
  }
}

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
