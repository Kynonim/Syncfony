import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'service.dart';

/// Mengunduh file asli dari server ke folder yang mudah diakses pengguna.
///
/// Android: folder eksternal aplikasi (`.../Android/data/<pkg>/files/Syncfony`).
/// iOS/macOS: Documents/Syncfony (terlihat di app Files bila file sharing aktif).
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

  final base = Platform.isAndroid
      ? (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory()
      : await getApplicationDocumentsDirectory();

  final dir = Directory('${base.path}${Platform.pathSeparator}Syncfony');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }

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

  return file;
}
