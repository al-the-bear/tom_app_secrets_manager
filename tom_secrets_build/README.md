# tom_secrets_build

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The manually driven CI of the Tom Secrets Manager, and its release build. It
analyzes and tests every package of the product's three repositories — this
one (`tom_app_secrets_manager`, the apps), `tom_secrets_manager` (the core
and the service) and `tom_secrets_clients` (the protocol, the clients and
`tsm`) — and runs the licence-boundary and standalone checks, strictly one
step after another, keeping every log; `:release` builds the release
archives for the platform it runs on.

**A person starts it, from the repository.** Nothing schedules it: no launchd
agent, crontab, systemd timer, git hook or GitHub workflow (Actions is
switched off for the product's repositories).

## Getting it

The package is not published (`publish_to: none`): it runs from a clone of
this repository. It needs the Flutter SDK (3.38 or later, for the apps and
the Dart it carries); `:conformance` needs Python 3 with `jsonschema`, and
the npm packages Node.js with npm.

## Running it

```bash
./ci.sh :all          # macOS, Linux: every stage, in order, past any red
./ci.sh :licences     # one stage; several may be named
./ci.sh --help        # the stages and options
```

On Windows, `.\ci.ps1 :all` from PowerShell or `ci.cmd :all` from cmd.exe.
The scripts take the Dart of the Flutter SDK (`FLUTTER_ROOT`, else `flutter`
on `PATH`, else `dart` on `PATH`) and run `pub get` here when the pubspec is
newer than the resolution.

The last line of output is the one summary line (`CI GREEN …` or
`CI RED …`, naming every red step and its log); the exit code is non-zero when
any step is red. The logs are in `testlog/<timestamp>/`, one per package and
step, plus `summary.txt`. Child processes run under a flutter lock, so two
sessions never run flutter at once.

## Where the repositories are

This repository is found by its `tom_repository.yaml`. The two others are
found, in order:

1. where `tom_secrets_build/repositories.yaml` says (paths absolute or
   relative to this repository's root):

   ```yaml
   secrets_manager: ../tom_secrets_manager
   secrets_clients: ../tom_secrets_clients
   ```

2. in the maintainers' workspace layout (its `buildkit_master.yaml` marks the
   workspace; where it keeps the two, `secretsCiWorkspaceLayout`);
3. cloned side by side with this one under their GitHub names
   (`tom_secrets_manager`, `tom_secrets_clients`).

Log and step names are paths relative to the folder that holds all three.

## Stages

- `:analyze`: `pub get` and `analyze` (infos fatal for Dart packages) in every
  package; `npm ci` and `npm run build` (`tsc` with the package's strict
  settings) in every npm package.
- `:test`: every package's suite (without the tags `licence-boundary`,
  `integration` and `standalone`), one full log per package; a package without
  `*_test.dart` is reported skipped; `npm ci` and `npm test` in every npm
  package.
- `:integration`: the integration suites against the real service (test tag
  `integration`, left out of `:test`): `tsm`'s builds the service as a binary
  (`dart build cli`), starts it through `tsm start` on demo vaults in a scratch
  data directory, and drives it with `tsm` and the Dart client.
- `:licences`: `pub get` in every package, `npm ci --omit=dev` in every npm
  package that links anything, then the licence-boundary check
  (`test/licence_boundary_test.dart`, tag `licence-boundary`); every non-Dart
  dependency manifest (`package.json`, `Cargo.toml`, `go.mod`, `pom.xml`,
  `pyproject.toml`, `setup.py`) is red until a closure check reads it, except a
  `go.mod` that requires nothing (its closure is the Go standard library, BSD-3)
  and a `package.json` with its `package-lock.json` (the npm closure check
  below).
- `:conformance`: the client conformance suite of `tom_secrets_clients`
  (`conformance/tool/conformance.py all`): the reference table current, the
  coverage gate, every runner against every case table; a runner without its
  toolchain is red here (Python 3 with `jsonschema` needed).
- `:standalone`: the standalone check (`test/standalone_test.dart`), below.
- `:all`: the stages above, in that order.
- `:release`: not part of `:all`: the release for this platform, below.
- `:mobile`: not part of `:all`: the mobile app's Android release, below.

The packages are found, never listed: every directory with a `pubspec.yaml`
(an npm package: a `package.json` with its `package-lock.json`) up to four
levels below a repository root, leaving out `example/`, `test/`,
build output, scratch, `node_modules/` and the Flutter platform folders. A
repository that is not checked out is a red step of every stage. The build
stages are the same on every platform; `:release` builds for the one it
runs on.

## The licence-boundary check

For every package, from what it resolves (`.dart_tool/package_config.json`)
and the `dependencies:` of every package it reaches (dev dependencies are not
linked):

- **No copyleft in a closure.** Every linked package carries a permissive
  licence (BSD, MIT, Apache-2.0, ISC, zlib). A GPL family, an unrecognised
  licence or a missing `LICENSE` is red. The closure walk and the
  classification are `tom_test_support`'s `licence_audit.dart`.
- **KDBX through one gate.** Only `tom_secrets_core` declares
  `tom_kdbx_store`; no package declares a KDBX library itself (`tom_kpasslib`,
  `kpasslib`, `tom_kdbx`, `kdbx`); the packages of `tom_secrets_clients`,
  `tom_secrets_relay` and this package link neither the store nor the core.

For every npm package (`secretsNpmProblems`): its `package.json` declares
`BSD-3-Clause` and its `LICENSE` is BSD-3; its closure is every entry of
`package-lock.json`'s `packages` but the root and those marked `dev`, and each
is classified by its licence file as `npm ci` installs it under
`node_modules/` (not by the lock's SPDX tag), with the same admitted licences.
A package that links nothing needs no install.

An exception is named in `secretsLicenceExceptions`, by package, with its
reason; the check prints each one on every run and turns red when one is no
longer needed. One is in force: `dbus` (MPL-2.0, file-level copyleft), which
`tom_secrets_desktop` and `tom_secrets_app` link on Linux through
`flutter_local_notifications_linux`, unmodified and stated in
`THIRD_PARTY.md` with its source. Every other closure is permissive.

## The standalone check

The product builds and is documented without the maintainers' workspace.
Over the tracked files of the three repositories (`git ls-files`):

- **No path dependency into another repository**: a `path:` entry of a
  pubspec's `dependencies`, `dev_dependencies` or `dependency_overrides`
  stays inside its own repository;
- **no `pubspec_overrides.yaml`**;
- **no path of the maintainers' workspace** in code or documents (its folder
  names, its machine names, its binaries variable; `secretsWorkspaceMarkers`).

A place that cannot follow the rules yet is named in
`secretsStandaloneExceptions` (`lib/src/standalone.dart`), by role and path,
with why and the todo that ends it; the check prints each on every run and
turns red when one is no longer needed.

## The release

`./ci.sh :release` builds, for the platform it runs on:

1. the service, `dart build cli` (its executable in `bin/`, `tom_pqc`'s
   native library in `lib/`);
2. `tsm`, `dart compile exe`;
3. the app, `flutter build <platform> --release`;
4. the release (`bin/assemble_release.dart`): the app with `tsm` and the
   service in its `tsm` folder (the layout of `tom_secrets_client`'s
   `distribution.dart`: `Tom Secrets Manager.app/Contents/Resources/tsm` on
   macOS, `<folder>/tsm` elsewhere; on macOS the bundle is signed again,
   ad-hoc), `LICENSE` and `THIRD_PARTY.md` with it, and the tools alone for a
   server; archived as `tom_secrets_manager-<version>-<platform>.zip`
   (`.tar.gz` on Linux) and `tom_secrets_tsm-<version>-<platform>…`, with
   `SHA256SUMS`, in `release/<version>/` (ignored by git);
5. a smoke run: a demo installation (`tom_secrets_desktop`'s
   `tool/demo_installation.dart`), the assembled `tsm` starting and unlocking
   the service beside it, its status read, the service stopped.

The version is `tom_secrets_app`'s. The archives are published as a release of
the `al-the-bear/tom_binaries` repository on GitHub, tag
`tom_secrets_manager-v<version>`, with `SHA256SUMS`.

## The mobile release

`./ci.sh :mobile` builds the mobile app's Android release on any platform
with the Android SDK: `flutter build apk --release` in `tom_secrets_mobile`,
signed with the key `TSM_ANDROID_SIGNING` names (a properties file outside
the repository: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`;
without a complete one the stage is red, never signed with the debug key),
copied to `release/<version>/tom_secrets_mobile-<version>-android.apk` (the
version is `tom_secrets_mobile`'s) and listed in that folder's `SHA256SUMS`.
It is installed directly on the phone (DP-204). The iOS app is not a release
file: it is built from Xcode onto the device under the user's free personal
team (DP-130).

## Configuration

- `tom_secrets_build/repositories.yaml`: where the two other repositories
  are (above).
- `FLUTTER_ROOT`: the Flutter SDK to use, instead of `flutter` on `PATH`.
- `TSM_ANDROID_SIGNING`: the Android signing properties file of `:mobile`.
- `secretsLicenceExceptions` (`lib/src/licence_boundary.dart`): the licence
  exceptions in force.
- `secretsStandaloneExceptions` (`lib/src/standalone.dart`): the places the
  standalone check lets pass.

## Limits

- `:release` builds for the platform it runs on only: each platform's
  archives are made on a machine of that platform.
- The macOS app is signed ad-hoc, not with a developer identity, and not
  notarised.
- A runner of the conformance suite without its toolchain is red, not
  skipped.

## Further documentation

- [The repository README](../README.md): installing, building, the packages.
- [`tom_secrets_desktop`](../tom_secrets_desktop/README.md): the demo
  installation the release's smoke run uses.
- The two other repositories it checks:
  [`al-the-bear/tom_secrets_manager`](https://github.com/al-the-bear/tom_secrets_manager)
  and
  [`al-the-bear/tom_secrets_clients`](https://github.com/al-the-bear/tom_secrets_clients).

## Status

Version 0.1.0. Its own suite covers the stage list, finding the repositories,
the licence rules and the boundary check, the standalone rules and check,
and the release assembly; the tagged parts (`licence-boundary`, `standalone`)
run as the CI stages of the same name.

## Licence

BSD-3-Clause, see [`LICENSE`](LICENSE). Tooling: nothing shipped depends on
it.
