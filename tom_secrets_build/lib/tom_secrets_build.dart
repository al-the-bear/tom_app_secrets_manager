/// Manually driven CI for the Tom Secrets Manager.
///
/// The stages ([secretsCiStages]) and what each does ([SecretsCiStages]),
/// the package discovery over the product's three repositories
/// ([SecretsCiWorkspace]), the licence-boundary rules
/// ([secretsBoundaryProblems]) and the command line ([secretsCiRunner]). The
/// run itself — the flutter lock, the streamed, kept-in-full child logs and
/// the one summary line — is `package:tom_build_base/ci.dart`'s. The entry
/// scripts `ci.sh`, `ci.ps1` and `ci.cmd` start `bin/tom_secrets_build.dart`.
library;

export 'src/ci_stages.dart';
export 'src/ci_tool.dart';
export 'src/ci_workspace.dart';
export 'src/licence_boundary.dart';
