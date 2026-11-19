import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfony/service.dart';
import 'package:syncfony/uix.dart';

void main() {
  group('formatBytes', () {
    test('bytes', () => expect(formatBytes(512), '512 B'));
    test('kilobytes', () => expect(formatBytes(2048), '2.0 KB'));
    test('megabytes', () => expect(formatBytes(5 * 1024 * 1024), '5.0 MB'));
    test('gigabytes', () => expect(formatBytes(3 * 1024 * 1024 * 1024), '3.00 GB'));
  });

  group('formatClock', () {
    test('detik', () => expect(formatClock(45), '00:45'));
    test('menit', () => expect(formatClock(125), '02:05'));
    test('jam', () => expect(formatClock(3725), '1:02:05'));
  });

  group('accentById', () {
    test('id dikenal', () => expect(accentById('blue').id, 'blue'));
    test('id tidak dikenal jatuh ke default', () {
      expect(accentById('tidak-ada').id, accentOptions.first.id);
    });
    test('null jatuh ke default', () {
      expect(accentById(null).id, accentOptions.first.id);
    });
  });

  group('hashFile', () {
    test('menghasilkan SHA-256 yang benar', () async {
      final dir = await Directory.systemTemp.createTemp('syncfony-test');
      final file = File('${dir.path}/hello.txt');
      await file.writeAsString('hello');

      final digest = await hashFile(file);
      expect(
        digest,
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );

      await dir.delete(recursive: true);
    });

    test('file sama menghasilkan hash sama', () async {
      final dir = await Directory.systemTemp.createTemp('syncfony-test');
      final a = File('${dir.path}/a.bin');
      final b = File('${dir.path}/b.bin');
      await a.writeAsBytes(List.generate(4096, (i) => i % 256));
      await b.writeAsBytes(List.generate(4096, (i) => i % 256));

      expect(await hashFile(a), await hashFile(b));

      await dir.delete(recursive: true);
    });
  });
}
