/// Runs the assembled release's `tsm` against a demo installation: starts
/// the service beside it, unlocks it with the demo password, reads its
/// status, stops it. Run by `ci.sh :release`.
///
/// ```text
/// dart run bin/smoke_release.dart <tools bin folder> <demo installation> <password>
/// ```
library;

import 'dart:io';

import 'package:tom_secrets_build/tom_secrets_build.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: smoke_release.dart <tools bin> <installation> <password>',
    );
    exitCode = 2;
    return;
  }
  final ok = await secretsSmokeRelease(
    toolsBin: args[0],
    installation: args[1],
    password: args[2],
    log: stdout.writeln,
  );
  exitCode = ok ? 0 : 1;
}
