/// Assembles a release from the parts the release stage built: the JSON file
/// [args] names holds `SecretsReleaseInputs`. Run by `ci.sh :release`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tom_secrets_build/tom_secrets_build.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: assemble_release.dart <inputs.json>');
    exitCode = 2;
    return;
  }
  final inputs = SecretsReleaseInputs.fromJson(
    (jsonDecode(File(args.single).readAsStringSync()) as Map)
        .cast<String, Object?>(),
  );
  await secretsAssembleRelease(inputs, log: stdout.writeln);
}
