/// The standalone check: the product builds and is documented without the
/// maintainers' workspace.
///
/// Three rules, over every tracked file of the three repositories:
///
/// - **No path dependency into another repository.** A `path:` entry of a
///   pubspec's `dependencies`, `dev_dependencies` or `dependency_overrides`
///   stays inside its own repository; across repositories a package comes
///   from pub.dev or a git URL.
/// - **No `pubspec_overrides.yaml`.**
/// - **No workspace path** in code or documents: the workspace's folders
///   ([secretsWorkspaceMarkers]: `_ai/`, `tom_ai/`, `app_webwork/`, …), its
///   machine names and its environment.
///
/// A place that cannot follow the rules yet is named in
/// [secretsStandaloneExceptions] with why and until when; the check prints
/// each on every run and turns red when one is no longer needed.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'ci_workspace.dart';

/// What names the maintainers' workspace in a file, with what each means.
const Map<String, String> secretsWorkspaceMarkers = {
  r'(^|[^A-Za-z0-9_])_ai/': 'the workspace\'s AI state folder',
  r'(^|[^A-Za-z0-9_])tom_ai/':
      'the workspace\'s folder of the tom_ai repositories',
  r'app_webwork/': 'another product\'s repository folder',
  r'tom_agent_container': 'the workspace\'s root',
  r'al_the_bear': 'the workspace\'s fleet',
  r'TOM_BINARY_PATH': 'the workspace\'s binaries layer',
};

/// The places that do not follow the rules yet, by role and path in the
/// repository (`apps:tom_secrets_ui/pubspec.yaml`; the roles as
/// `SecretsCiWorkspace.roleOf` names them), each with why and the todo that
/// ends it.
const Map<String, String> secretsStandaloneExceptions = {
  // The CI's default is this workspace's layout (the todo's requirement:
  // the locations configurable, the workspace layout only the default), and
  // its tests use it as a fixture.
  'apps:tom_secrets_build/lib/src/ci_workspace.dart':
      'the default location of the two other repositories (the maintainers\' '
      'workspace layout)',
  'apps:tom_secrets_build/lib/src/standalone.dart':
      'the markers this check looks for',
  'apps:tom_secrets_build/test/ci_workspace_test.dart':
      'the workspace layout as a fixture',
  'apps:tom_secrets_build/test/standalone_rules_test.dart':
      'the markers as fixtures',
  // Kept: the maintainers' test tool is compiled onto every machine's PATH
  // by the workspace's binaries build, whose output folder is this
  // variable; elsewhere the file is unused (`dart compile exe` builds it).
  'secrets_manager:tom_secrets_import_cleaner/buildkit.yaml':
      'the workspace\'s binaries build of the maintainers\' test tool',
};

/// File names the text rule reads: code, documents and build files.
final RegExp secretsStandaloneTextFiles = RegExp(
  r'(\.(dart|md|ya?ml|json|ts|js|mjs|cjs|py|go|sh|ps1|cmd|txt|swift|cpp|h|'
  r'cmake|gradle|xcconfig)|/CMakeLists\.txt|/\.gitignore)$',
);

/// File names the text rule skips: locks and other generated resolutions.
const Set<String> secretsStandaloneSkippedFiles = {
  'pubspec.lock',
  'package-lock.json',
};

/// Every problem of the repository of role [role] at [root], by
/// `<role>:<path>`: the path dependencies into another repository, the
/// `pubspec_overrides.yaml` files and the workspace paths, over its tracked
/// files ([files], paths relative to [root] with `/`).
Map<String, List<String>> secretsStandaloneProblems({
  required String role,
  required String root,
  required List<String> files,
}) {
  final problems = <String, List<String>>{};
  void add(String file, String problem) =>
      problems.putIfAbsent('$role:$file', () => []).add(problem);
  final markers = {
    for (final MapEntry(:key, :value) in secretsWorkspaceMarkers.entries)
      RegExp(key, multiLine: true): value,
  };
  for (final file in files) {
    final name = p.posix.basename(file);
    final full = p.join(root, file);
    if (name == 'pubspec_overrides.yaml') {
      add(file, 'a pubspec_overrides.yaml');
    }
    if (name == 'pubspec.yaml') {
      for (final out in _crossRepositoryPaths(full, root)) {
        add(file, '$out by path from outside the repository');
      }
    }
    if (secretsStandaloneSkippedFiles.contains(name) ||
        !secretsStandaloneTextFiles.hasMatch('/$file')) {
      continue;
    }
    final String text;
    try {
      text = File(full).readAsStringSync();
    } on FileSystemException {
      continue;
    }
    for (final MapEntry(key: pattern, value: what) in markers.entries) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final line = '\n'.allMatches(text.substring(0, match.start)).length + 1;
      add(file, 'line $line names $what');
    }
  }
  return problems;
}

/// The dependencies of the pubspec at [pubspecPath] taken by a path that
/// leaves [repositoryRoot], as `name (path)`.
List<String> _crossRepositoryPaths(String pubspecPath, String repositoryRoot) {
  final Object? doc;
  try {
    doc = loadYaml(File(pubspecPath).readAsStringSync());
  } on Object {
    return const [];
  }
  if (doc is! YamlMap) return const [];
  final out = <String>[];
  for (final section in [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    final deps = doc[section];
    if (deps is! YamlMap) continue;
    for (final MapEntry(:key, :value) in deps.entries) {
      if (value is! YamlMap || value['path'] is! String) continue;
      final target = p.normalize(
        p.join(p.dirname(pubspecPath), value['path'] as String),
      );
      if (!p.isWithin(repositoryRoot, target) &&
          !p.equals(repositoryRoot, target)) {
        out.add('$key (${value['path']})');
      }
    }
  }
  return out;
}

/// The tracked files of the repository at [root] (`git ls-files`), paths
/// relative to it with `/`; without git, every file but build output.
List<String> secretsTrackedFiles(String root) {
  final result = Process.runSync('git', [
    'ls-files',
    '-z',
  ], workingDirectory: root);
  if (result.exitCode == 0) {
    return [
      for (final f in (result.stdout as String).split('\x00'))
        if (f.isNotEmpty) f,
    ]..sort();
  }
  final out = <String>[];
  for (final e in Directory(root).listSync(recursive: true)) {
    if (e is! File) continue;
    final rel = p.relative(e.path, from: root).replaceAll(r'\', '/');
    final parts = rel.split('/');
    if (parts.any(
      (s) =>
          s.startsWith('.') && s != '.gitignore' ||
          secretsCiSkippedDirectories.contains(s) &&
              !const {'test', 'example'}.contains(s),
    )) {
      continue;
    }
    out.add(rel);
  }
  return out..sort();
}

/// Every problem of [workspace]'s three repositories, by `<role>:<path>`.
Map<String, List<String>> secretsWorkspaceStandaloneProblems(
  SecretsCiWorkspace workspace,
) {
  final all = <String, List<String>>{};
  for (final repository in workspace.repositories) {
    final root = workspace.repositoryDir(repository);
    if (!Directory(root).existsSync()) continue;
    all.addAll(
      secretsStandaloneProblems(
        role: workspace.roleOf(repository),
        root: root,
        files: secretsTrackedFiles(root),
      ),
    );
  }
  return all;
}
