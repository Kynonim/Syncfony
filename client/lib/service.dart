import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';

class MediaItem {
  final String id;
  final String hash;
  final String originalName;
  final String extension;
  final String mimetype;
  final int thumbSize;
  final int fileSize;
  final int? width;
  final int? height;
  final bool hasThumb;
  final bool hasLive;
  final double? duration;
  final String? deviceName;
  final String? lens;
  final String? focalLength;
  final String? aperture;
  final String? exposure;
  final int? iso;
  final String? software;
  final DateTime timestamp;

  MediaItem({
    required this.id,
    required this.hash,
    required this.originalName,
    required this.extension,
    required this.mimetype,
    required this.thumbSize,
    required this.fileSize,
    this.width,
    this.height,
    required this.hasThumb,
    required this.hasLive,
    this.duration,
    this.deviceName,
    this.lens,
    this.focalLength,
    this.aperture,
    this.exposure,
    this.iso,
    this.software,
    required this.timestamp,
  });

  bool get isVideo => mimetype.startsWith('video/');

  String get megapixels {
    if (width == null || height == null || width! <= 0 || height! <= 0) return "";
    final mp = (width! * height!) / 1000000.0;
    return mp >= 1.0 ? "${mp.toStringAsFixed(1)} MP" : "${(mp * 1000).round()} KP";
  }

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final sizes = (json['size'] as List<dynamic>?) ?? [0, 0];
    final ratio = (json['aspect_ratio'] as List<dynamic>?) ?? [null, null];
    return MediaItem(
      id: (json['id'] ?? '').toString(),
      hash: (json['hash'] ?? '').toString(),
      originalName: (json['original_name'] ?? 'unknown').toString(),
      extension: (json['extension'] ?? '').toString(),
      mimetype: (json['mimetype'] ?? 'application/octet-stream').toString(),
      thumbSize: (sizes.isNotEmpty ? (sizes[0] as num?)?.toInt() : 0) ?? 0,
      fileSize: (sizes.length > 1 ? (sizes[1] as num?)?.toInt() : 0) ?? 0,
      width: ratio.isNotEmpty ? (ratio[0] as num?)?.toInt() : null,
      height: ratio.length > 1 ? (ratio[1] as num?)?.toInt() : null,
      hasThumb: json['has_thumb'] == true,
      hasLive: json['has_live'] == true,
      duration: (json['duration'] as num?)?.toDouble(),
      deviceName: _optionalText(json['device_name']),
      lens: _optionalText(json['lens']),
      focalLength: _optionalText(json['focal_length']),
      aperture: _optionalText(json['aperture']),
      exposure: _optionalText(json['exposure']),
      iso: (json['iso'] as num?)?.toInt(),
      software: _optionalText(json['software']),
      timestamp: DateTime.tryParse((json['timestamp'] ?? '').toString())?.toLocal() ?? DateTime.now(),
    );
  }

  static String? _optionalText(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }
}

class MediaPage {
  final List<MediaItem> items;
  final int? total;
  final bool hasMore;
  final int offset;

  MediaPage({
    required this.items,
    required this.total,
    required this.hasMore,
    required this.offset,
  });

  factory MediaPage.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];
    return MediaPage(
      items: rawItems.map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList(),
      total: (json['total'] as num?)?.toInt(),
      hasMore: json['has_more'] == true,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }
}

class ServerStats {
  final int totalCount;
  final int totalSize;
  final int thumbSize;

  ServerStats({
    required this.totalCount,
    required this.totalSize,
    required this.thumbSize,
  });

  factory ServerStats.fromJson(Map<String, dynamic> json) {
    return ServerStats(
      totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
      totalSize: (json['total_size'] as num?)?.toInt() ?? 0,
      thumbSize: (json['thumb_size'] as num?)?.toInt() ?? 0,
    );
  }
}

class Api {
  final String url;
  final String? token;
  http.Client client = http.Client();

  Api(this.url, {this.token});

  String get normalizedUrl => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  Map<String, String> get authHeaders {
    final t = token?.trim();
    if (t == null || t.isEmpty) return {};
    return {'Authorization': 'Bearer $t'};
  }

  void explode() {
    client.close();
    client = http.Client();
  }

  Future<Map<String, dynamic>> upload(
    File file,
    String filename,
    String mimetype, {
    DateTime? timestamp,
    String? deviceId,
    File? liveFile,
  }) async {
    final req = http.MultipartRequest("POST", Uri.parse("$normalizedUrl/api/upload"));
    req.headers.addAll(authHeaders);
    req.headers["Expect"] = "100-continue";
    if (timestamp != null) {
      req.fields["timestamp"] = timestamp.toUtc().toIso8601String();
    }
    if (deviceId != null && deviceId.isNotEmpty) {
      req.fields["device_id"] = deviceId;
    }
    req.files.add(
      await http.MultipartFile.fromPath(
        "file",
        file.path,
        filename: filename,
        contentType: MediaType.parse(mimetype),
      ),
    );
    if (liveFile != null && await liveFile.exists()) {
      req.files.add(
        await http.MultipartFile.fromPath(
          "live_file",
          liveFile.path,
          filename: "${filename}_live.mov",
          contentType: MediaType.parse("video/quicktime"),
        ),
      );
    }
    final res = await client.send(req);
    final body = await res.stream.bytesToString();
    if (res.statusCode != 200) throw Exception("Upload failed (${res.statusCode}): $body");
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<MediaPage> listMedia({int limit = 100, int offset = 0}) async {
    final uri = Uri.parse("$normalizedUrl/api/assets").replace(queryParameters: {
      'limit': '$limit',
      'offset': '$offset',
    });
    final res = await client.get(uri, headers: authHeaders).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw Exception("List failed (${res.statusCode}): ${res.body}");
    return MediaPage.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<Set<String>> listHashes() async {
    final res = await client
        .get(Uri.parse("$normalizedUrl/api/assets/hashes"), headers: authHeaders)
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw Exception("Hashes failed (${res.statusCode}): ${res.body}");
    return (jsonDecode(res.body) as List<dynamic>).map((e) => e.toString()).toSet();
  }

  Future<Set<String>> checkHashes(List<String> hashes) async {
    if (hashes.isEmpty) return <String>{};
    final res = await client
        .post(
          Uri.parse("$normalizedUrl/api/assets/check"),
          headers: {...authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({'hashes': hashes}),
        )
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw Exception("Check failed (${res.statusCode}): ${res.body}");
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return ((json['existing'] as List<dynamic>?) ?? const []).map((e) => e.toString()).toSet();
  }

  /// Membaca ulang EXIF untuk media lama yang belum punya info kamera.
  Future<Map<String, int>> backfillMetadata() async {
    final res = await client
        .post(Uri.parse("$normalizedUrl/api/assets/backfill"), headers: authHeaders)
        .timeout(const Duration(minutes: 3));
    if (res.statusCode != 200) {
      throw Exception("Backfill failed (${res.statusCode}): ${res.body}");
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return {
      'scanned': (json['scanned'] as num?)?.toInt() ?? 0,
      'updated': (json['updated'] as num?)?.toInt() ?? 0,
    };
  }

  Future<void> deleteMedia(String id) async {
    final res = await client
        .delete(Uri.parse("$normalizedUrl/api/assets/$id"), headers: authHeaders)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw Exception("Delete failed (${res.statusCode}): ${res.body}");
    }
  }

  Future<ServerStats> getStats() async {
    final res = await client
        .get(Uri.parse("$normalizedUrl/api/stats"), headers: authHeaders)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception("Stats failed (${res.statusCode}): ${res.body}");
    return ServerStats.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<bool> checkServer() async {
    final res = await client
        .get(Uri.parse("$normalizedUrl/api/health"))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode == 200 && res.body == "https://rikyripaldo.my.id") {
      return true;
    }
    throw Exception(res.body);
  }

  String _withTokenQuery(String base) {
    final t = token?.trim();
    if (t == null || t.isEmpty) return base;
    return "$base?token=${Uri.encodeQueryComponent(t)}";
  }

  String getFileUrl(String id) => _withTokenQuery("$normalizedUrl/api/assets/$id/file");
  String getThumbUrl(String id) => _withTokenQuery("$normalizedUrl/api/assets/$id/thumb");
  String getLiveUrl(String id) => _withTokenQuery("$normalizedUrl/api/assets/$id/live");
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Menghitung SHA-256 secara streaming agar file besar tidak dimuat ke memori.
Future<String> hashFile(File file) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return sink.value?.toString() ?? '';
}

enum _UploadResult { uploaded, skipped }

class BackupController extends ChangeNotifier {
  /// Menyimpan pemetaan assetId perangkat -> hash SHA-256 agar status backup bisa
  /// diverifikasi ulang ke server (bukan sekadar cache lokal).
  static const String _indexKey = "syncfony_backup_index";
  static const String _legacyKey = "syncfony_backed_up_asset_ids";

  /// Batas jumlah aset yang dipindai per pemindaian galeri.
  int scanLimit = 5000;

  bool isScanning = false;
  bool isUploading = false;
  bool isPaused = false;
  bool permissionGranted = false;

  List<AssetEntity> localAssets = [];
  Map<String, String> localIndex = {};
  Set<String> serverHashes = {};

  Api? _api;

  int totalQueued = 0;
  int completedCount = 0;
  int skippedCount = 0;
  int failedCount = 0;
  String? currentFileName;
  String? lastError;

  int get processedCount => completedCount + skippedCount + failedCount;
  int get pendingCount => localAssets.where((a) => !isBackedUp(a.id)).length;
  int get backedUpCount => localAssets.where((a) => isBackedUp(a.id)).length;
  double get progress => totalQueued == 0 ? 0.0 : processedCount / totalQueued;

  /// Attach API agar [scan] dapat menyinkronkan indeks lokal dengan server.
  void attachApi(Api api) {
    _api = api;
  }

  /// Status backup diverifikasi ke server: jika hash tidak lagi ada di server
  /// (mis. database/file dihapus langsung), item kembali dianggap belum ter-backup.
  bool isBackedUp(String assetId) {
    final hash = localIndex[assetId];
    return hash != null && serverHashes.contains(hash);
  }

  Future<void> _loadLocalIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey);
    localIndex = {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        localIndex = decoded.map((key, value) => MapEntry(key, value.toString()));
      } catch (_) {
        localIndex = {};
      }
    }
    // Cache lama (hanya daftar id tanpa hash) tidak bisa diverifikasi -> dibuang.
    if (prefs.containsKey(_legacyKey)) {
      await prefs.remove(_legacyKey);
    }
  }

  Future<void> _persistIndex() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_indexKey, jsonEncode(localIndex));
  }

  /// Menyinkronkan hash server lalu memangkas entri lokal yang sudah tidak ada
  /// di server. Mengembalikan false jika hash server gagal dimuat.
  Future<bool> _syncWithServer() async {
    final api = _api;
    if (api == null) return false;
    try {
      final hashes = await api.listHashes();
      serverHashes = hashes;
      final before = localIndex.length;
      localIndex.removeWhere((_, hash) => !hashes.contains(hash));
      if (localIndex.length != before) {
        await _persistIndex();
      }
      return true;
    } catch (e) {
      lastError = t('svc.indexSyncFailed', args: {'error': '$e'});
      return false;
    }
  }

  Future<bool> requestPermission() async {
    try {
      final state = await PhotoManager.requestPermissionExtend();
      permissionGranted = state.isAuth || state.hasAccess;
    } catch (e) {
      permissionGranted = false;
      lastError = e.toString();
    }
    notifyListeners();
    return permissionGranted;
  }

  Future<void> scan({bool requestPermissions = true}) async {
    if (isScanning) return;
    isScanning = true;
    lastError = null;
    notifyListeners();

    try {
      await _loadLocalIndex();
      // Verifikasi ke server: jika server dikosongkan, hitungan backup ikut 0.
      await _syncWithServer();

      if (requestPermissions) {
        if (!await requestPermission()) {
          lastError = t('svc.permissionDenied');
          localAssets = [];
          return;
        }
      } else {
        // Dipanggil dari background isolate: jangan memunculkan dialog izin.
        permissionGranted = true;
      }

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      if (albums.isEmpty) {
        localAssets = [];
        return;
      }

      final album = albums.first;
      final available = await album.assetCountAsync;
      if (available <= 0) {
        localAssets = [];
        return;
      }

      final end = available < scanLimit ? available : scanLimit;
      localAssets = await album.getAssetListRange(start: 0, end: end);
    } catch (e) {
      lastError = e.toString();
    } finally {
      isScanning = false;
      notifyListeners();
    }
  }

  Future<void> startBackup(Api api, {int? maxItems, bool requestPermissions = true}) async {
    attachApi(api);
    if (isUploading) return;
    if (!permissionGranted || localAssets.isEmpty) {
      await scan(requestPermissions: requestPermissions);
    }
    final queue = localAssets.where((a) => !isBackedUp(a.id)).toList();
    if (queue.isEmpty) {
      lastError = null;
      notifyListeners();
      return;
    }
    await _runQueue(api, queue, maxItems: maxItems);
  }

  /// Upload manual untuk aset tertentu (dipakai tab Lokal).
  Future<void> uploadAssets(Api api, List<AssetEntity> assets) async {
    attachApi(api);
    if (isUploading || assets.isEmpty) return;
    await _runQueue(api, assets);
  }

  Future<void> _runQueue(Api api, List<AssetEntity> queue, {int? maxItems}) async {
    final batch = maxItems != null && queue.length > maxItems
        ? queue.sublist(0, maxItems)
        : queue;
    isUploading = true;
    isPaused = false;
    totalQueued = batch.length;
    completedCount = 0;
    skippedCount = 0;
    failedCount = 0;
    lastError = null;
    notifyListeners();

    await _loadServerHashes(api);

    for (final asset in batch) {
      if (isPaused) break;
      currentFileName = asset.title;
      notifyListeners();
      try {
        final result = await _uploadOne(api, asset);
        if (result == _UploadResult.skipped) {
          skippedCount++;
        } else {
          completedCount++;
        }
        await _persistIndex();
      } catch (e) {
        failedCount++;
        lastError = e.toString();
      }
      notifyListeners();
    }

    isUploading = false;
    currentFileName = null;
    notifyListeners();
  }

  Future<void> _loadServerHashes(Api api) async {
    try {
      serverHashes = await api.listHashes();
    } catch (e) {
      // Bukan kegagalan fatal: upload tetap jalan, deduplikasi ditangani server.
      serverHashes = {};
      lastError = t('svc.indexLoadFailed', args: {'error': '$e'});
    }
  }

  Future<_UploadResult> _uploadOne(Api api, AssetEntity asset) async {
    final file = await asset.file;
    if (file == null || !await file.exists()) {
      throw Exception(t('svc.fileUnavailable'));
    }

    final name = asset.title ?? file.uri.pathSegments.last;
    final mime = lookupMimeType(file.path) ??
        (asset.type == AssetType.video ? 'video/mp4' : 'image/jpeg');

    final localHash = await hashFile(file);
    if (serverHashes.contains(localHash)) {
      // Sudah ada di server (mis. cache lokal hilang / perangkat baru).
      _markBackedUp(asset, localHash);
      return _UploadResult.skipped;
    }

    File? liveFile;
    if (asset.isLivePhoto) {
      final candidate = await asset.fileWithSubtype;
      if (candidate != null && candidate.path != file.path) {
        liveFile = candidate;
      }
    }

    final response = await _withRetry(() => api.upload(
          file,
          name,
          mime,
          timestamp: asset.createDateTime,
          liveFile: liveFile,
        ));

    _markBackedUp(asset, response['hash']?.toString());
    return _UploadResult.uploaded;
  }

  void _markBackedUp(AssetEntity asset, String? hash) {
    if (hash == null || hash.isEmpty) return;
    localIndex[asset.id] = hash;
    serverHashes.add(hash);
  }

  Future<T> _withRetry<T>(Future<T> Function() action, {int attempts = 3}) async {
    Object? lastFailure;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await action();
      } catch (e) {
        lastFailure = e;
        if (attempt < attempts - 1) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
    }
    throw lastFailure ?? Exception(t('svc.uploadFailed'));
  }

  void pauseBackup() {
    if (!isUploading) return;
    isPaused = true;
    notifyListeners();
  }

  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_indexKey);
    await prefs.remove(_legacyKey);
    localIndex.clear();
    notifyListeners();
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return "$bytes B";
  if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
  if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
}

String formatClock(int totalSeconds) {
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    return "$hours:${(minutes % 60).toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
  }
  return "${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
}
