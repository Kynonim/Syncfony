import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'service.dart';

/// Indeks file asli yang sudah diunduh agar viewer bisa membaca dari disk.
class DownloadIndex {
  DownloadIndex._();

  static const String _prefsKey = 'syncfony_download_index';

  static String _serverKey(String serverUrl) =>
      serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;

  static Future<Map<String, dynamic>> _read(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(SharedPreferences prefs, Map<String, dynamic> data) async {
    await prefs.setString(_prefsKey, jsonEncode(data));
  }

  /// Mengembalikan file lokal bila masih ada; entri basi dibersihkan otomatis.
  /// [candidates] dipakai untuk menemukan unduhan lama yang belum tercatat.
  static Future<File?> lookup(
    String serverUrl,
    String mediaId, {
    List<String> candidates = const [],
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = await _read(prefs);
      final key = _serverKey(serverUrl);
      final serverMap = data[key];

      if (serverMap is Map) {
        final path = serverMap[mediaId];
        if (path is String && path.isNotEmpty) {
          final file = File(path);
          if (await file.exists()) return file;
        }
        if (serverMap.containsKey(mediaId)) {
          serverMap.remove(mediaId);
          data[key] = serverMap;
          await _write(prefs, data);
        }
      }

      if (candidates.isEmpty) return null;

      final dirs = await _lookupDirectories();
      for (final dir in dirs) {
        for (final name in candidates) {
          if (name.trim().isEmpty) continue;
          final file = File('${dir.path}${Platform.pathSeparator}$name');
          if (await file.exists()) {
            await save(serverUrl, mediaId, file.path);
            return file;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Mencari file lokal untuk [item], termasuk unduhan sebelum indeks ini ada.
  static Future<File?> lookupMedia(String serverUrl, MediaItem item) {
    final name = item.originalName.trim().split('/').last.split('\\').last;
    final extension = item.extension.isEmpty ? 'bin' : item.extension;
    return lookup(
      serverUrl,
      item.id,
      candidates: [
        if (name.isNotEmpty) name,
        '${item.hash}.$extension',
      ],
    );
  }

  static Future<void> save(String serverUrl, String mediaId, String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = await _read(prefs);
      final key = _serverKey(serverUrl);
      final existing = data[key];
      final serverMap = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      serverMap[mediaId] = path;
      data[key] = serverMap;
      await _write(prefs, data);
    } catch (_) {
      // Indeks opsional: viewer tetap bisa memakai server bila gagal menyimpan.
    }
  }

  static Future<void> remove(String serverUrl, String mediaId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = await _read(prefs);
      final key = _serverKey(serverUrl);
      final serverMap = data[key];
      if (serverMap is! Map) return;
      serverMap.remove(mediaId);
      data[key] = serverMap;
      await _write(prefs, data);
    } catch (_) {}
  }
}

/// Mengunduh file asli dari server ke folder yang mudah diakses pengguna.
///
/// Android: `Documents/Syncfony` di penyimpanan bersama bila OS mengizinkan,
/// lalu fallback ke folder eksternal aplikasi (`.../files/Syncfony`).
/// iOS/macOS/desktop: Documents/Syncfony.
Future<File> downloadOriginal(
  Api api,
  MediaItem item, {
  void Function(double progress)? onProgress,
}) async {
  final request = http.Request('GET', Uri.parse(api.getFileUrl(item.id)));
  request.headers.addAll(api.authHeaders);

  final response = await api.client.send(request);
  if (response.statusCode != 200) {
    throw Exception('HTTP ${response.statusCode}');
  }

  final dir = await _downloadDirectory();
  await dir.create(recursive: true);

  final extension = item.extension.isEmpty ? 'bin' : item.extension;
  final fallbackName = '${item.hash}.$extension';
  final name = item.originalName.trim().isEmpty ? fallbackName : item.originalName.trim();
  final file = File('${dir.path}${Platform.pathSeparator}$name');

  final sink = file.openWrite();
  final total = response.contentLength;
  var received = 0;

  try {
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total != null && total > 0) {
        onProgress?.call((received / total).clamp(0.0, 1.0));
      }
    }
  } finally {
    await sink.close();
  }

  await DownloadIndex.save(api.normalizedUrl, item.id, file.path);
  return file;
}

Directory? _cachedDownloadDir;
List<Directory>? _cachedLookupDirs;

Future<List<Directory>> _lookupDirectories() async {
  final cached = _cachedLookupDirs;
  if (cached != null) return cached;

  final dirs = <Directory>[await _downloadDirectory()];
  if (Platform.isAndroid) {
    final external = await getExternalStorageDirectory();
    if (external != null) {
      final legacy = Directory('${external.path}${Platform.pathSeparator}Syncfony');
      if (!dirs.any((dir) => dir.path == legacy.path)) dirs.add(legacy);
    }
  }
  return _cachedLookupDirs = dirs;
}

Future<Directory> _downloadDirectory() async {
  final cached = _cachedDownloadDir;
  if (cached != null) return cached;

  final separator = Platform.pathSeparator;

  if (Platform.isAndroid) {
    final publicDocuments = await _tryPublicAndroidDocuments();
    if (publicDocuments != null) return _cachedDownloadDir = publicDocuments;

    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    return _cachedDownloadDir = Directory('${base.path}${separator}Syncfony');
  }

  final base = await getApplicationDocumentsDirectory();
  return _cachedDownloadDir = Directory('${base.path}${separator}Syncfony');
}

/// Mencoba `Documents/Syncfony` di penyimpanan bersama Android.
///
/// Android 10+ (scoped storage) bisa menolak tulisan ke folder publik tanpa
/// izin khusus; dalam kasus itu fungsi mengembalikan `null` agar pemanggil
/// memakai folder aplikasi sebagai fallback.
Future<Directory?> _tryPublicAndroidDocuments() async {
  try {
    final external = await getExternalStorageDirectory();
    if (external == null) return null;
    if (!external.path.replaceAll('\\', '/').contains('/Android/data/')) {
      return null;
    }

    // .../Android/data/<pkg>/files -> akar penyimpanan (/storage/emulated/0).
    var root = external;
    for (var i = 0; i < 4; i++) {
      final parent = root.parent;
      if (parent.path == root.path) return null;
      root = parent;
    }

    final target = Directory(
      '${root.path}${Platform.pathSeparator}Documents'
      '${Platform.pathSeparator}Syncfony',
    );
    await target.create(recursive: true);

    // Pastikan benar-benar bisa ditulis sebelum dipakai.
    final probe = File('${target.path}${Platform.pathSeparator}.syncfony_write_test');
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return target;
  } catch (_) {
    return null;
  }
}
