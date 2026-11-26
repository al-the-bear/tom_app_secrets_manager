// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Writes a demo installation for trying the app by hand: a primary vault
/// naming a team vault, both `file:` vaults under demo passwords, demo
/// entries (a login with an overlay, an API token with a key and a TOTP, a
/// note), and a bootstrap whose `admin_executables` names the given app.
///
/// ```text
/// dart run tool/demo_installation.dart <folder> [<app executable>]
/// ```
///
/// Then, with `TSM_DATA_DIR=<folder>/data` and `TSM_RUNTIME_DIR=<folder>/run`:
/// `tsm start --service <tom_secrets_service>`, and the app. The primary's
/// master password is `primary-demo-pw`. Demo data only.
library;

import 'dart:io';

import 'package:tom_kdbx_store/tom_kdbx_store.dart'
    show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_core/tom_secrets_core.dart';

const _argon2 = KdbxArgon2(
  type: KdbxArgon2Type.argon2id,
  memory: 1 << 20,
  iterations: 1,
);

KdbxEntry _add(KdbxFile file, String path, Map<String, String> fields) {
  final parts = path.split('/');
  var group = file.body.rootGroup;
  for (final name in parts.sublist(0, parts.length - 1)) {
    group =
        group.groups.where((g) => g.name.get() == name).firstOrNull ??
        file.createGroup(parent: group, name: name);
  }
  final entry = KdbxEntry.create(file, group)..label = parts.last;
  group.addEntry(entry);
  for (final MapEntry(:key, :value) in fields.entries) {
    entry.setString(
      KdbxKey(key),
      key == 'Password' ? ProtectedValue.fromString(value) : PlainValue(value),
    );
  }
  return entry;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: demo_installation.dart <folder> [<app executable>]');
    exit(2);
  }
  final dir = Directory(args.first)..createSync(recursive: true);
  final team = tomSecretsNewVault(
    tomSecretsVaultCredentials(password: 'team-demo-pw'),
    'team',
    argon2: _argon2,
  );
  _add(team, 'Api/Token', {'Password': 'demo-api-token'}).tags.set('prod;api');
  File('${dir.path}/team.kdbx').writeAsBytesSync(await team.save());

  final primary = tomSecretsNewVault(
    tomSecretsVaultCredentials(password: 'primary-demo-pw'),
    'primary',
    argon2: _argon2,
  );
  _add(primary, 'Db/Main', {
    'Password': 'demo-db-pw',
    'UserName': 'demo-user',
    'URL': 'https://db.example',
  });
  _add(primary, '@host:bomber/Db/Main', {'Password': 'demo-bomber-pw'});
  final bot = _add(primary, 'Bot', {
    'Password': 'demo-bot-token',
    'tsm.key': 'telegram.bot_token',
    'tsm.type': 'api-token',
  });
  TomSecretsTotp(
    tomSecretsBase32Decode('JBSWY3DPEHPK3PXP')!,
    issuer: 'Demo',
    account: 'demo',
  ).writeTo(bot);
  _add(primary, 'Recovery codes', {
    'tsm.type': 'note',
    'Notes': 'demo-code-1 demo-code-2',
  });
  TomSecretsPrimaryVaults(primary).put(
    TomSecretsVaultKeys(
      name: 'team',
      locator: 'file:${dir.path}/team.kdbx',
      password: 'team-demo-pw',
    ),
  );
  File('${dir.path}/primary.kdbx').writeAsBytesSync(await primary.save());
  Directory('${dir.path}/data').createSync();
  final app = args.length > 1 ? args[1] : null;
  File('${dir.path}/data/bootstrap.yaml').writeAsStringSync(
    'primary: file:${dir.path}/primary.kdbx\n'
    'device_key: keyfile\n'
    // The identity key in its file: no keychain item for a demo.
    'identity_key: file\n'
    'runtime_dir: ${dir.path}/run\n'
    'host: demo-host\n'
    '${app == null ? '' : 'admin_executables:\n  - $app\n'}',
  );
  stdout.writeln('demo installation in ${dir.path}');
}
