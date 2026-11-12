/// `tom_secrets_build` — started by `ci.sh` / `ci.ps1` / `ci.cmd`.
///
/// ```bash
/// dart run bin/tom_secrets_build.dart :all
/// ```
library;

import 'package:tom_secrets_build/tom_secrets_build.dart';

Future<void> main(List<String> args) async {
  // runToCompletion sets the exit code and never calls exit(), so the summary
  // line written by the run is flushed and stays the last line of output.
  await secretsCiRunner().runToCompletion(args);
}
