# Tom Secrets Manager applications — development guidelines

Guidelines for the packages in `app_secrets_manager` (the `tom_secrets_*`
application, capability, build and testkit packages).

## Boundaries

- The apps reach KDBX only through `tom_secrets_core`; no package here
  imports a KDBX library.
- One composition root per kind of application (`tom_secrets_app` for the
  desktop, `tom_secrets_mobile` for phones and tablets); capability packages
  decide no implementation.
- `tom_secrets_relay` imports no KDBX and carries its own `LICENSE` and
  closure check.
- The apps take `tom_reusable_ui` by path from the sibling `app_webwork`
  (`../app_webwork/reusable/tom_reusable_ui`); a build host needs both
  repositories checked out.
- A shipped dependency gets its row in `THIRD_PARTY.md`.
- **Source unification only:** `tom_secrets_core` and the service take the
  workspace's published packages (`tom_core_storage`, `tom_core_sync`,
  `tom_github_api`) from pub.dev, `tom_reusable_ui` takes them by path. A
  Flutter package that reaches both carries a tracked `pubspec_overrides.yaml`
  pointing them at pub.dev at exactly the version the workspace checkout
  carries, with the reason in the file. It never reaches for an unpublished
  API; a version that differs is published first.
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
  run with `testkit` from the package root, and the manual CI
  `app_secrets_manager/tom_secrets_build/ci.sh :all`.
- **CLI tools** are built on `tom_build_base`.
- **Locks:** a library keeps its `pubspec.lock` ignored; an application
  package (a tracked `bin/*.dart`, or a Flutter app) tracks it with an
  anchored `!/pubspec.lock` in its own `.gitignore` (`/tom_app_locks`).
- **No CI on GitHub.** Actions is switched off for this repository; builds,
  tests and checks are started by a person from the clone.
- **Real secrets never enter the repository or a test.** Tests and corpora use
  demo data under demo keys.
- **New packages** are registered in the workspace's
  `_copilot_guidelines/projects_and_repos.md` and listed in this repository's
  README.

The workspace-wide guidelines in the container's `_copilot_guidelines/` apply
as well. The design is the idea document
`_ai/quests/tom_core/ideas/tom_secrets_manager/tom_secrets_manager.md`.

## Documents

| Document | Purpose |
| -------- | ------- |
| [index.md](index.md) | This index: the repository's rules and its guideline documents |
