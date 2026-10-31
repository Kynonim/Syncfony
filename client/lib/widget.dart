import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:syncfony/api.dart';
import 'package:http/http.dart' as http;

class GaleryManager extends StatefulWidget {
  final Api api;
  const GaleryManager({super.key, required this.api});
  @override
  State<GaleryManager> createState() => GaleryManagerState();
}

class GaleryManagerState extends State<GaleryManager> {
  bool isHasMore = true;
  bool isLoading = false, isStopRequest = false;
  bool isAutoUpload = true, isUploading = false;
  int pages = 0, uploadTotal = 0, uploadDone = 0;

  AssetPathEntity? allMedia;
  List<AssetEntity> mediaList = [];
  Set<String> uploadedIds = {};

  static const pageSize = 80;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      notify("Izin galery ditolak", isError: true);
      return;
    }
    uploadedIds = await MediaStore.load();
    final paths = await PhotoManager.getAssetPathList(type: .common, onlyAll: true);
    if (paths.isEmpty) {
      notify("Galery kosong", isError: true);
      return;
    }
    allMedia = paths.first;
    await loadMore(reset: true);
    PhotoManager.addChangeCallback(onMediaChanged);
    await PhotoManager.startChangeNotify();
  }

  Future<void> loadMore({bool reset = false}) async {
    if (!isHasMore && !reset) return;
    setState(() => isLoading = true);
    try {
      if (reset) {
        pages = 0;
        mediaList = [];
        isHasMore = true;
      }
      final page = await allMedia!.getAssetListPaged(page: pages, size: pageSize);
      if (page.length < pageSize) isHasMore = false;
      if (mounted) {
        setState(() {
          mediaList.addAll(page);
          pages += 1;
        });
      }
    } catch (e) {
      notify("Gagal load galery: $e", isError: true);
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> onMediaChanged(MethodCall call) async {
    if (!isAutoUpload) return;
    if (call.method != "change") return;
    final args = call.arguments as Map;
    final created = (args["create"] ?? []) as List;
    final newEntities = <AssetEntity>[];

    for (final item in created) {
      final id = item["id"] as String?;
      if (id == null || uploadedIds.contains(id)) continue;
      final entity = await AssetEntity.fromId(id);
      if (entity != null) newEntities.add(entity);
    }
    if (newEntities.isEmpty) return;
    await runUpload(newEntities, silentError: true);
    await loadMore(reset: true);
  }

  Future<void> runUpload(List<AssetEntity> list, {bool silentError = false}) async {
    if (isUploading) return;
    setState(() {
      isUploading = true;
      isStopRequest = false;
      uploadTotal = list.length;
      uploadDone = 0;
    });
    for (final element in list) {
      if (isStopRequest) break;
      if (uploadedIds.contains(element.id)) {
        setState(() => uploadDone++);
        continue;
      }
      await uploadEntity(element, silent: silentError);
      if (mounted) setState(() => uploadDone++);
    }
    final stopped = isStopRequest;
    if (mounted) {
      setState(() {
        isUploading = false;
        isStopRequest = false;
      });
    }
    if (stopped) notify("Upload dihentikan");
  }

  Future<void> uploadEntity(AssetEntity entity, {bool silent = false}) async {
    if (isStopRequest) return;
    final file = await entity.file;
    if (file == null) return;
    final name = entity.title ?? file.path.split("/").last;
    final mime = entity.mimeType ?? lookupMimeType(file.path) ?? "application/octet-stream";

    try {
      final res = await widget.api.upload(file, name, mime);
      await MediaStore.add(entity.id);
      if (mounted) setState(() => uploadedIds.add(entity.id));
      if (res["dedupilcated"] == true) {}
    } on http.ClientException {
      notify("Upload dibatalkan");
    } catch (e) {
      if (!silent) notify("Gagal upload $name: $e", isError: true);
    } finally {
      try { await file.delete(); } catch (_) {}
    }
  }

  Future<void> uploadAll() async {
    final pending = mediaList.where((element) => !uploadedIds.contains(element.id)).toList();
    if (pending.isEmpty) {
      notify("Semua sudah diupload");
      return;
    }
    await runUpload(pending);
    await loadMore(reset: true);
  }

  void stopUpload() {
    isStopRequest = true;
    widget.api.cancelAll();
    notify("Menghentikan upload...");
  }

  void notify(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        duration: Duration(milliseconds: isError ? 3000 : 1500),
      ),
    );
  }

  @override
  void dispose() {
    PhotoManager.stopChangeNotify();
    PhotoManager.removeChangeCallback(onMediaChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isShowProgress = isUploading && uploadTotal > 0;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          "U`Own Media",
          style: TextStyle(fontWeight: .w600),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(color: Colors.white.withValues(alpha: 0.5)),
          ),
        ),
        actions: [
          Container(
            margin: .only(right: 8),
            padding: .symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.55),
              borderRadius: .circular(20),
            ),
            child: Row(
              children: [
                const Text("Auto", style: TextStyle(fontSize: 16)),
                Switch(
                  value: isAutoUpload,
                  onChanged: (v) => setState(() => isAutoUpload = v),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (isShowProgress) buildProgresBar(context, uploadTotal, uploadDone),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => loadMore(reset: true),
              child: mediaList.isEmpty ? const Center(
                child: Text("Tidak ada media")
              ) : NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.pixels >= n.metrics.maxScrollExtent - 300) {
                    loadMore();
                  }
                  return false;
                },
                child: GridView.builder(
                  padding: .all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 3 / 4,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  scrollCacheExtent: .viewport(2.0),
                  addAutomaticKeepAlives: true,
                  itemCount: mediaList.length,
                  itemBuilder: (context, index) {
                    final list = mediaList[index];
                    final isUploaded = uploadedIds.contains(list.id);
                    return MediaTile(
                      entity: list,
                      isUploaded: isUploaded,
                      onTap: () => runUpload([list]),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: isUploading ? FloatingActionButton.extended(
        onPressed: stopUpload,
        backgroundColor: Colors.red.shade600,
        icon: const Icon(Icons.stop),
        label: const Text("Stop"),
      ) : FloatingActionButton.extended(
        onPressed: uploadAll,
        icon: const Icon(Icons.cloud_upload),
        label: const Text("Upload"),
      ),
    );
  }
}

class MediaTile extends StatelessWidget {
  final bool isUploaded;
  final AssetEntity entity;
  final VoidCallback onTap;

  const MediaTile({
    super.key,
    required this.isUploaded,
    required this.entity,
    required this.onTap
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: isUploaded ? .all(color: Colors.green, width: 1) : null,
          borderRadius: .circular(8),
        ),
        child: ClipRRect(
          borderRadius: .circular(8),
          child: Stack(
            fit: .expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: entity.thumbnailDataWithSize(
                  const ThumbnailSize.square(360),
                ),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Image.memory(snapshot.data!, fit: .cover);
                  }
                  return Container(
                    color: Colors.grey.shade300,
                    child: const Icon(Icons.image, color: Colors.grey),
                  );
                },
              ),
              if (entity.type == AssetType.video) Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  padding: .all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: .circular(4),
                  ),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 14),
                ),
              ),
              if (isUploaded) const Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.check_circle, color: Colors.green, size: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget buildProgresBar(BuildContext context, int uploadTotal, int uploadDone) {
  final progress = uploadTotal == 0 ? 0.0 : uploadDone / uploadTotal;
  return Material(
    elevation: 2,
    child: Padding(
      padding: .symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "Uploading $uploadDone / $uploadTotal",
                  style: const TextStyle(fontWeight: .w600),
                ),
              ),
              Text("${(progress * 100).toStringAsFixed(0)}%"),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: .circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.grey.shade300,
            ),
          ),
        ],
      ),
    ),
  );
}
