#!/usr/bin/env bash
# Manually driven CI for the Tom Secrets Manager — macOS and Linux.
#
# Started by a person, from the repository. Nothing schedules it: no launchd
# agent, crontab, systemd timer, hook or cloud workflow runs it.
#
#   ./ci.sh :all          every stage, in order, past any red
#   ./ci.sh :test         one stage (several may be named: ./ci.sh :analyze :licences)
#   ./ci.sh --help        the stages and options
#
# The last line of output is the one summary line; the exit code is non-zero
# when any step is red. Logs: tom_secrets_build/testlog/<timestamp>/.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The Dart that belongs to the Flutter SDK, so the tool finds that same SDK's
# flutter: FLUTTER_ROOT, then flutter on PATH, then a plain dart on PATH.
DART=""
if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/dart" ]; then
  DART="$FLUTTER_ROOT/bin/dart"
elif command -v flutter >/dev/null 2>&1; then
  DART="$(dirname "$(command -v flutter)")/dart"
elif command -v dart >/dev/null 2>&1; then
  DART="$(command -v dart)"
fi
if [ -z "$DART" ] || [ ! -x "$DART" ]; then
  echo "ci.sh: no Flutter SDK found — put flutter on PATH or set FLUTTER_ROOT" >&2
  exit 2
fi

cd "$here" || exit 2
if [ ! -f .dart_tool/package_config.json ] || [ pubspec.yaml -nt .dart_tool/package_config.json ]; then
  "$DART" pub get || { echo "ci.sh: dart pub get failed in $here" >&2; exit 2; }
fi
exec "$DART" run bin/tom_secrets_build.dart "$@"
