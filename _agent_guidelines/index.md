# Tom Secrets Manager applications — development guidelines

Guidelines for the packages of this repository (the `tom_secrets_*`
application, capability, build and testkit packages).

## Boundaries

- The apps reach KDBX only through `tom_secrets_core`; no package here
  imports a KDBX library.
- One composition root per kind of application (`tom_secrets_app` for the
  desktop, `tom_secrets_mobile` for phones and tablets); capability packages
  decide no implementation.
- `tom_secrets_relay` imports no KDBX and carries its own `LICENSE` and
  closure check.
- Every dependency comes from pub.dev (the Tom UI modules `tom_ui_support`,
  `tom_host_ui`, `tom_credentials_ui`, `tom_sync_ui` among them), or by path
  from a sibling package of this repository; no `pubspec_overrides.yaml`
  (`ci.sh :standalone` holds it).
- A shipped dependency gets its row in `THIRD_PARTY.md`.
- **Desktop plugins:** each third-party plugin sits behind a port of
  `tom_secrets_ui`, implemented in `tom_secrets_desktop` (DP-32); where a
  plugin needs hand edits of the app's runner, the capability is this
  package's own platform code instead (start at login on macOS).
- **macOS builds through Swift Package Manager**, not CocoaPods: a plugin
  without a `Package.swift` cannot be taken.

## Rules for every package

- **BSD-3.** Every package carries the BSD-3 licence and copyright notice of
  the repository's `LICENSE`; no package's dependency closure may hold a
  GPL-licensed or other copyleft package.
- **Quality per change:** `dart analyze` clean (no Problems pane issue), tests
  run with `testkit` (or `dart test`) from the package root, and the manual
  CI `tom_secrets_build/ci.sh :all`.
- **CLI tools** are built on `tom_build_base`.
- **Locks:** a library keeps its `pubspec.lock` ignored; an application
  package (a tracked `bin/*.dart`, or a Flutter app) tracks it with an
  anchored `!/pubspec.lock` in its own `.gitignore`.
- **No CI on GitHub.** Actions is switched off for this repository; builds,
  tests and checks are started by a person from the clone.
- **Real secrets never enter the repository or a test.** Tests and corpora use
  demo data under demo keys.
- **New packages** are listed in this repository's README (and in the
  project register of the maintainers' workspace).
- **Standalone.** Nothing shipped names the maintainers' workspace: no path
  dependency into another repository, no `pubspec_overrides.yaml`, no
  workspace path in code or documents (`tom_secrets_build/ci.sh :standalone`).

The maintainers' workspace-wide guidelines apply as well. The design
document the code cites is not published with the source.

## Documents

| Document | Purpose |
| -------- | ------- |
| [index.md](index.md) | This index: the repository's rules and its guideline documents |
