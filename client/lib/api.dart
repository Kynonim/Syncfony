import 'dart:convert';
import 'dart:io';
import 'package:http_parser/http_parser.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  final String url;
  http.Client client = http.Client();

  Api(this.url);

  void cancelAll() {
    client.close();
    client = http.Client();
  }

  Future<Map<String, dynamic>> upload(File file, String filename, String mimetype) async {
    final req = http.MultipartRequest("POST", Uri.parse("$url/api/upload"));
    req.headers["Expect"] = "100-continue";
    req.files.add(await http.MultipartFile.fromPath("file", file.path, filename: filename, contentType: MediaType.parse(mimetype)));
    final res = await client.send(req);
    final body = await res.stream.bytesToString();
    if (res.statusCode != 200) throw Exception(body);
    return jsonDecode(body);
  }

  Future<List<dynamic>> listAssets() async {
    final res = await client.get(Uri.parse("$url/api/assets"));
    if (res.statusCode != 200) throw Exception(res.body);
    return jsonDecode(res.body);
  }

  String fileUrl(String id) => "$url/api/assets/$id/file";
  String thumbUrl(String id) => "$url/api/assets/$id/thumb";
}

class MediaStore {
  static const key = "uploads_assets_ids";

  static Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(key) ?? []).toSet();
  }

  static Future<void> add(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(key) ?? []).toSet();
    set.add(id);
    await prefs.setStringList(key, set.toList());
  }

  static Future<void> addAll(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(key) ?? []).toSet();
    set.addAll(ids);
    await prefs.setStringList(key, set.toList());
  }
}
