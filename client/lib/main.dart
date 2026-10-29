import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:syncfony/api.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Syncfony',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true
      ),
      home: const Syncfony(),
    );
  }
}

class Syncfony extends StatefulWidget {
  const Syncfony({super.key});
  @override
  State<Syncfony> createState() => SyncfonyState();
}

class SyncfonyState extends State<Syncfony> {
  final api = Api("http://localhost:2026");

  Set<String> uploadedIds = {};
  List<AssetEntity> media = [];
  bool stopRequest = false;
  bool loading = false, autoUpload = true, hasMore = true;
  AssetPathEntity? allMedia;
  int pages = 0;
  static const pageSize = 80;

  @override
  void initState() {
    init();
    super.initState();
  }

  Future<void> init() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      alert("Izin galery ditolak");
    }
    uploadedIds = await MediaStore.load();
    final paths = await PhotoManager.getAssetPathList(
      type: .common,
      onlyAll: true
    );
    if (paths.isEmpty) {
      alert("Galery kosong");
      return;
    }
    allMedia = paths.first;
    await loadMedia(reset: true);

    PhotoManager.addChangeCallback(onMediaChanged);
    await PhotoManager.startChangeNotify();
  }

  Future<void> loadMedia({bool reset = false}) async {
    if (!hasMore && !reset) return;
    setState(() => loading = true);
    try {
      if (reset) {
        pages = 0;
        media = [];
        hasMore = true;
      }
      final page = await allMedia!.getAssetListPaged(page: pages, size: pageSize);
      if (page.length < pageSize) hasMore = false;
      setState(() {
        media.addAll(page);
        pages += 1;
      });

    } catch (e) {
      alert("Gagal load galery: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> onMediaChanged(MethodCall call) async {
    if (!autoUpload) return;
    if (call.method != "change") return;
    final args = call.arguments as Map;
    final created = (args["create"] ?? []) as List;
    for (final item in created) {
      final id = item["id"] as String?;
      if (id == null || uploadedIds.contains(id)) continue;
      final entity = await AssetEntity.fromId(id);
      if (entity == null) continue;
      await uploadEntity(entity, silent: true);
    }
    await loadMedia(reset: true);
  }

  Future<void> uploadEntity(AssetEntity entity, {bool silent = false}) async {
    if (stopRequest) return;
    final file = await entity.file;
    if (file == null) return;
    final name = entity.title ?? file.path.split("/").last;
    final mime = lookupMimeType(file.path) ?? "application/octet-stream";
    try {
      final res = await api.upload(file, name, mime);
      await MediaStore.add(entity.id);
      setState(() => uploadedIds.add(entity.id));
      if (!silent) {
        alert(res["deduplicated"] == true ? "Duplikat dilewati: $name" : "Upload: $name", duration: 200);
      }
    } on http.ClientException {
      alert("Upload berhenti!");
    } catch (e) {
      if (!silent) alert("Gagal upload $name: $e");
    } finally {
      try { await file.delete(); } catch (_) {}
    }
  }

  Future<void> uploadSelected() async {
    if (stopRequest) return;
    setState(() {
      loading = true;
      stopRequest = false;
    });
    for (final e in media) {
      if (stopRequest) break;
      if (uploadedIds.contains(e.id)) continue;
      await uploadEntity(e);
    }
    setState(() => loading = false);
    if (!stopRequest) await loadMedia(reset: true);
    if (stopRequest) {
      setState(() => stopRequest = false);
      alert("Upload dihentikan");
    }
  }

  Future<void> stopUpload() async {
    stopRequest = true;
    api.cancelAll();
    setState(() => loading = false);
    alert("Menghentikan upload...");
    return Future.value();
  }

  void alert(String message, {int duration = 2000}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: Duration(milliseconds: duration)));
  }

  @override
  void dispose() {
    PhotoManager.stopChangeNotify();
    PhotoManager.removeChangeCallback(onMediaChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Syncfony"),
        actions: [
          Row(
            children: [
              const Text("Auto"),
              Switch(
                value: autoUpload,
                onChanged: (v) => setState(() => autoUpload = v),
              )
            ],
          )
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => loadMedia(reset: true),
        child: media.isEmpty ? const Center(child: Text("Tidak ada apapun")) : NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
              loadMedia();
            }
            return false;
          },
          child: GridView.builder(
            padding: .all(4),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: media.length,
            itemBuilder: (context, index) {
              final md = media[index];
              final uploaded = uploadedIds.contains(md.id);
              return MediaTile(
                entity: md,
                uploaded: uploaded,
                onTap: () => uploadEntity(md),
              );
            },
          ),
        ),
      ),
      floatingActionButton: loading ? FloatingActionButton.extended(
        onPressed: stopUpload,
        backgroundColor: Colors.red,
        icon: const Icon(Icons.stop),
        label: const Text("Cancel"),
      ) : FloatingActionButton.extended(
        onPressed: uploadSelected,
        icon: const Icon(Icons.upload),
        label: const Text("Upload"),
      ),
    );
  }
}

class MediaTile extends StatelessWidget {
  final AssetEntity entity;
  final bool uploaded;
  final VoidCallback onTap;

  const MediaTile({
    super.key,
    required this.entity,
    required this.uploaded,
    required this.onTap
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: uploaded ? .all(color: Colors.green, width: 2) : null,
          borderRadius: .circular(4),
        ),
        child: ClipRRect(
          borderRadius: .circular(4),
          child: Stack(
            fit: .expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: entity.thumbnailDataWithSize(
                  const ThumbnailSize.square(240),
                ),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Image.memory(snapshot.data!, fit: .cover);
                  }
                  return Container(
                    color: Colors.grey.shade300,
                    child: const Icon(Icons.image),
                  );
                },
              ),
              if (entity.type == AssetType.video) const Positioned(
                right: 4,
                bottom: 4,
                child: Icon(Icons.videocam, color: Colors.white, size: 16),
              ),
              if (uploaded) const Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.check_circle, color: Colors.green, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
