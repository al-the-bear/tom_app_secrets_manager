import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

void main() {
  group('secretsScratchDir', () {
    test('is a fresh folder under the package ztmp/test', () {
      final dir = secretsScratchDir('scratch_fresh');
      expect(
        dir.path,
        p.join(Directory.current.path, 'ztmp', 'test', 'scratch_fresh'),
      );
      secretsWriteFile(dir, 'a/b.txt', 'left over');
      final again = secretsScratchDir('scratch_fresh');
      expect(again.listSync(), isEmpty);
    });

    test('refuses a name that leaves ztmp/test', () {
      expect(() => secretsScratchDir(''), throwsArgumentError);
      expect(() => secretsScratchDir('../x'), throwsArgumentError);
      expect(() => secretsScratchDir('/abs'), throwsArgumentError);
    });

    test('secretsWriteFile creates the folders it needs', () {
      final dir = secretsScratchDir('scratch_write');
      final file = secretsWriteFile(dir, 'x/y/z.txt', 'body');
      expect(file.readAsStringSync(), 'body');
    });
  });
}
