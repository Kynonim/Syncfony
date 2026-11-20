import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'service.dart';
import 'thumbnail_cache.dart';
import 'thumbnail_store.dart';

/// Menampilkan thumbnail media server dengan urutan sumber:
/// memori -> disk (bisa offline) -> jaringan (lalu disimpan ke memori + disk).
class MediaThumbnail extends StatefulWidget {
  const MediaThumbnail({
    super.key,
    required this.item,
    required this.api,
    this.fit = BoxFit.cover,
  });

  final MediaItem item;
  final Api api;
  final BoxFit fit;

  @override
  State<MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends State<MediaThumbnail> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.api.normalizedUrl != widget.api.normalizedUrl) {
      _bytes = null;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.item.id;

    final memory = ThumbnailCache.get(id);
    if (memory != null) {
      if (mounted) {
        setState(() {
          _bytes = memory;
          _loading = false;
        });
      }
      return;
    }

    final disk = await ThumbnailStore.read(id);
    if (!mounted) return;
    if (disk != null) {
      ThumbnailCache.put(id, disk);
      setState(() {
        _bytes = disk;
        _loading = false;
      });
      return;
    }

    final url = widget.item.hasThumb
        ? widget.api.getThumbUrl(id)
        : widget.api.getFileUrl(id);

    try {
      final response = await widget.api.client
          .get(Uri.parse(url), headers: widget.api.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        ThumbnailCache.put(id, response.bodyBytes);
        await ThumbnailStore.write(id, response.bodyBytes);
        if (!mounted) return;
        setState(() {
          _bytes = response.bodyBytes;
          _loading = false;
        });
        return;
      }
    } catch (_) {
      // Offline atau server mati: biarkan placeholder.
    }

    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
      );
    }

    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Center(
      child: Icon(
        widget.item.isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );
  }
}
