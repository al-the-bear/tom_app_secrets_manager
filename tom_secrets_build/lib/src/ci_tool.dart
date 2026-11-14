/// The command-line surface: one `tom_build_base` command per stage plus
/// `all` (`package:tom_build_base/ci.dart`'s `ciToolDefinition`). Every stage
/// finds its own packages ([SecretsCiWorkspace]), because the set is "the
/// packages of the product's repositories", not a user's `--project`
/// selection.
library;

import 'dart:io';

import 'package:tom_build_base/ci.dart';
import 'package:tom_build_base/tom_build_base.dart';

import 'ci_stages.dart';
import 'ci_workspace.dart';

/// This package's version, as its pubspec declares it (a test holds the two
/// together).
const String secretsCiVersion = '0.1.0';

/// The tool definition: one command per stage, plus `all`.
final ToolDefinition secretsCiTool = ciToolDefinition(
  name: 'tom_secrets_build',
  description:
      'Manually driven CI for the Tom Secrets Manager: analyze, test and the '
      'licence-boundary check over every package of its three repositories, '
      'strictly serially, keeping every log. Started by a person '
      '(ci.sh / ci.ps1 / ci.cmd); nothing schedules it.',
  version: secretsCiVersion,
  stages: secretsCiStages,
  descriptions: secretsCiStageDescriptions,
  helpFooter:
      'Logs: tom_secrets_build/testlog/<timestamp>/ — one per package and '
      'step, plus summary.txt. The last line of output is the summary.',
);

/// Builds the runner: the stages named on the command line run in the order
/// given, past any red, into one log folder, ending with one summary line.
ToolRunner secretsCiRunner({
  SecretsCiWorkspace? workspace,
  StringSink? console,
}) => ciToolRunner(
  tool: secretsCiTool,
  console: console,
  runStages: (requested, out) =>
      secretsCiRun(
        workspace: workspace ?? SecretsCiWorkspace.find(from: _packageDir()),
        console: out,
      ).run(
        resolveCiStages(
          requested,
          stages: secretsCiStages,
          inAll: (s) => !secretsCiStagesNotInAll.contains(s),
        ),
      ),
);

/// This package's directory, from the running script (`bin/…dart`), so the
/// tool finds its repository wherever it is started from.
String? _packageDir() {
  final script = Platform.script;
  if (!script.isScheme('file')) return null;
  return File.fromUri(script).parent.parent.path;
}
