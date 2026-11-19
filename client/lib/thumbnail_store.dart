import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Cache thumbnail di disk supaya galeri server tetap bisa menampilkan
/// thumbnail saat perangkat sedang offline.
class ThumbnailStore {
  ThumbnailStore._();

  static Directory? _cacheDir;

  static Future<Directory> _dir() async {
    final cached = _cacheDir;
    if (cached != null) return cached;

    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}thumbs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _cacheDir = dir;
  }

  static Future<File> _file(String id) async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}$id.jpg');
  }

  static Future<Uint8List?> read(String id) async {
    try {
      final file = await _file(id);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String id, Uint8List bytes) async {
    try {
      final file = await _file(id);
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {
      // Cache bersifat opsional: gagal menulis tidak boleh mengganggu UI.
    }
  }

  static Future<void> delete(String id) async {
    try {
      final file = await _file(id);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<int> sizeBytes() async {
    try {
      final dir = await _dir();
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clear() async {
    try {
      final dir = await _dir();
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
