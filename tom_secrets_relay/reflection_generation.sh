#!/usr/bin/env bash
# Regenerate bin/tom_secrets_relay.reflection.dart: the reflection metadata
# the relay needs (its configuration class, its endpoint service, and the
# framework types reached through the tom_core_server barrel). The root is
# bin/tom_secrets_relay.dart, configured in build.yaml.
#
# Run from the package root:
#   ./reflection_generation.sh
# Verify instead of regenerate (fails, naming the file, on drift):
#   ./reflection_generation.sh --check
#
# --no-cache: the framework (tom_core_kernel, holding the reflector class)
# comes from pub.dev, and a cached analyzer summary carries no syntax tree
# for the reflector's constructor, which the generator reads its
# capabilities from. Without the cache it analyses every package from source
# (about three minutes). The SEVERE lines it prints are the framework's own
# (mixin applications, record type arguments) and concern no type the relay
# reflects.
set -e
cd "$(dirname "$0")"
# Resolve the Dart SDK: an explicit $DART wins, otherwise `dart` from PATH.
# Why no baked-in SDK path: the fleet's hosts install Dart in different places,
# so any absolute default is wrong on most of them and fails with a bare "no
# such file or directory" quoting a path the reader has never seen. Failing
# loudly, with the remedy in the message, is cheaper than guessing.
DART="${DART:-$(command -v dart || true)}"
if [ -z "$DART" ]; then
  echo "reflection_generation.sh: no 'dart' found on PATH." >&2
  echo "  Install the Dart or Flutter SDK and put its bin/ on PATH, or rerun as:" >&2
  echo "    DART=/path/to/dart $0" >&2
  exit 1
fi
"$DART" run tom_reflection_generator --no-cache "$@"
