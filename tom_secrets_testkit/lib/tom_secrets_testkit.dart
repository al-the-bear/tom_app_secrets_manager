/// The Tom Secrets Manager's own test fixtures that more than one package's
/// suite needs. A dev dependency only: nothing shipped depends on it.
///
/// Holds the scratch folder every suite builds its fixtures in. The vault
/// factory, the fake GitHub remote and the fake service for the UI tests join
/// it with the packages that first need them.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// A fresh, empty scratch directory `ztmp/test/<name>` under the package the
/// suite runs in (its gitignored `ztmp/`), never the system temp directory
/// (the workspace rule). A directory left by an earlier run is replaced.
Directory secretsScratchDir(String name, {String? packageDir}) {
  if (name.isEmpty || p.isAbsolute(name) || p.split(name).contains('..')) {
    throw ArgumentError.value(name, 'name', 'a relative name inside ztmp/test');
  }
  final dir = Directory(
    p.join(packageDir ?? Directory.current.path, 'ztmp', 'test', name),
  );
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  return dir..createSync(recursive: true);
}

/// Writes [content] to [relative] under [root], creating its folders.
File secretsWriteFile(Directory root, String relative, String content) =>
    File(p.join(root.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
