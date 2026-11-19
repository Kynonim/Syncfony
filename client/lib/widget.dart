import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfony/background.dart';
import 'package:syncfony/l10n.dart';
import 'package:syncfony/service.dart';
import 'package:syncfony/thumbnail_cache.dart';
import 'package:syncfony/uix.dart';
import 'package:video_player/video_player.dart';

class SyncfonyGallery extends StatefulWidget {
  final String serverUrl;
  final String? token;

  const SyncfonyGallery({
    super.key,
    required this.serverUrl,
    this.token,
  });

  static String routeName = "Media";
  static String routePath = "/media";

  @override
  State<SyncfonyGallery> createState() => SyncfonyGalleryState();
}

class SyncfonyGalleryState extends State<SyncfonyGallery> {
  int currentTab = 0;

  final scaffoldKey = GlobalKey<ScaffoldState>();

  /// Satu controller per tab: ScrollController tidak boleh dipakai dua
  /// scrollable sekaligus, dan tab-tab sekarang tetap hidup (Offstage).
  final ScrollController mediaScroll = ScrollController();
  final ScrollController localScroll = ScrollController();
  final ScrollController backupScroll = ScrollController();
  final ScrollController settingsScroll = ScrollController();

  /// Tab yang pernah dibuka: hanya tab ini yang dibangun (lazy) lalu dijaga
  /// hidup supaya posisi scroll & thumbnail tidak dimuat ulang.
  final Set<int> visitedTabs = {0};

  /// Dipisah dari `setState` agar hide/show header-navbar saat scroll tidak
  /// me-rebuild seluruh halaman.
  final ValueNotifier<bool> navbarVisible = ValueNotifier(true);

  /// Jumlah kolom grid (2–8) sebagai notifier: cubit hanya me-rebuild grid.
  final ValueNotifier<int> gridColumnsNotifier = ValueNotifier(3);

  int get gridColumns => gridColumnsNotifier.value;

  late Api api;
  final BackupController backup = BackupController();
  late final TextEditingController urlEditController;
  late final TextEditingController tokenEditController;

  bool isLoadingMedia = true;
  String? mediaError;
  List<MediaItem> mediaItems = [];
  ServerStats? serverStats;

  static const int _mediaPageSize = 60;
  int _mediaOffset = 0;
  bool hasMoreMedia = false;
  bool isLoadingMoreMedia = false;
  int? mediaTotal;

  bool isLocalSelecting = false;
  final Set<String> selectedLocalIds = {};
  bool backgroundEnabled = false;
  bool isBackfilling = false;
  String accentId = accentOptions.first.id;

  static const String _gridColumnsPrefsKey = gridColumnsPrefsKey;
  static const String _blurScalePrefsKey = glassBlurPrefsKey;

  final Map<int, Offset> _activePointers = {};
  double? _pinchStartDistance;
  int _pinchStartColumns = 3;

  @override
  void initState() {
    super.initState();
    api = Api(widget.serverUrl, token: widget.token);
    backup.attachApi(api);
    urlEditController = TextEditingController(text: widget.serverUrl);
    tokenEditController = TextEditingController(text: widget.token ?? '');

    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      glassBlurScale = (prefs.getDouble(_blurScalePrefsKey) ?? 1.0)
          .clamp(minGlassBlurScale, maxGlassBlurScale)
          .toDouble();
      gridColumnsNotifier.value =
          (prefs.getInt(_gridColumnsPrefsKey) ?? 3).clamp(2, 8).toInt();
      setState(() {
        backgroundEnabled = prefs.getBool(backgroundEnabledPrefsKey) ?? false;
        accentId = accentById(prefs.getString(accentPrefsKey)).id;
      });
    });

    mediaScroll.addListener(() {
      _updateNavbarVisibility(mediaScroll);
      if (!mediaScroll.hasClients) return;
      final position = mediaScroll.position;
      if (position.hasContentDimensions && position.pixels >= position.maxScrollExtent - 600) {
        _loadMoreMedia();
      }
    });
    localScroll.addListener(() => _updateNavbarVisibility(localScroll));
    backupScroll.addListener(() => _updateNavbarVisibility(backupScroll));
    settingsScroll.addListener(() => _updateNavbarVisibility(settingsScroll));

    _loadInitial();
  }

  void _updateNavbarVisibility(ScrollController controller) {
    if (!controller.hasClients) return;
    final direction = controller.position.userScrollDirection;
    if (direction == ScrollDirection.reverse) {
      if (navbarVisible.value) navbarVisible.value = false;
    } else if (direction == ScrollDirection.forward) {
      if (!navbarVisible.value) navbarVisible.value = true;
    }
  }

  ScrollPhysics get _gridPhysics => _activePointers.length >= 2
      ? const NeverScrollableScrollPhysics()
      : const AlwaysScrollableScrollPhysics();

  double _pointerSpread() {
    final points = _activePointers.values.take(2).toList();
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }

  void _handleGridPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 2) {
      _pinchStartDistance = _pointerSpread();
      _pinchStartColumns = gridColumns;
      setState(() {});
    }
  }

  void _handleGridPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.position;

    final start = _pinchStartDistance;
    if (start == null || start < 8 || _activePointers.length < 2) return;

    final ratio = _pointerSpread() / start;
    if (ratio <= 0.01) return;

    // Cubit keluar -> kolom lebih sedikit (foto membesar), cubit masuk -> sebaliknya.
    final target = (_pinchStartColumns / ratio).round().clamp(2, 8).toInt();
    if (target != gridColumnsNotifier.value) {
      // Hanya grid yang di-rebuild (lewat ValueListenableBuilder), bukan halaman.
      gridColumnsNotifier.value = target;
    }
  }

  void _handleGridPointerEnd(PointerEvent event) {
    final removed = _activePointers.remove(event.pointer);
    if (removed == null) return;
    if (_activePointers.length < 2 && _pinchStartDistance != null) {
      _pinchStartDistance = null;
      // Simpan sekali saat cubit selesai (hindari tulis prefs berulang).
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setInt(_gridColumnsPrefsKey, gridColumnsNotifier.value),
      );
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadInitial() async {
    await Future.wait([
      _fetchMedia(),
      _fetchStats(),
    ]);
  }

  Future<void> _fetchMedia() async {
    setState(() {
      isLoadingMedia = true;
      mediaError = null;
    });
    try {
      final page = await api.listMedia(limit: _mediaPageSize, offset: 0);
      if (!mounted) return;
      setState(() {
        mediaItems = page.items;
        _mediaOffset = page.items.length;
        hasMoreMedia = page.hasMore;
        mediaTotal = page.total;
        isLoadingMedia = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        mediaError = e.toString();
        isLoadingMedia = false;
      });
    }
  }

  Future<void> _loadMoreMedia() async {
    if (isLoadingMoreMedia || !hasMoreMedia) return;
    setState(() => isLoadingMoreMedia = true);
    try {
      final page = await api.listMedia(limit: _mediaPageSize, offset: _mediaOffset);
      if (!mounted) return;
      setState(() {
        mediaItems = [...mediaItems, ...page.items];
        _mediaOffset += page.items.length;
        hasMoreMedia = page.hasMore;
        if (page.total != null) mediaTotal = page.total;
        isLoadingMoreMedia = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => isLoadingMoreMedia = false);
    }
  }

  Future<void> _fetchStats() async {
    try {
      final stats = await api.getStats();
      if (!mounted) return;
      setState(() => serverStats = stats);
    } catch (_) {}
  }

  void _toggleBackup() {
    if (backup.isUploading) {
      backup.pauseBackup();
      return;
    }
    backup.startBackup(api).whenComplete(() {
      if (!mounted) return;
      _fetchMedia();
      _fetchStats();
    });
  }

  Future<void> _backfillCameraInfo() async {
    if (isBackfilling) return;
    setState(() => isBackfilling = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('server.backfillRunning'))),
    );
    try {
      final result = await api.backfillMetadata();
      await _fetchMedia();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('server.backfillDone', args: {
            'updated': '${result['updated'] ?? 0}',
            'scanned': '${result['scanned'] ?? 0}',
          })),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('server.backfillFailed', args: {'error': '$e'})),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => isBackfilling = false);
    }
  }

  Future<void> _deleteMedia(MediaItem item) async {
    try {
      await api.deleteMedia(item.id);
      if (!mounted) return;
      setState(() {
        mediaItems.removeWhere((m) => m.id == item.id);
        if (_mediaOffset > 0) _mediaOffset -= 1;
      });
      _fetchStats();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('viewer.deleted'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('viewer.deleteFailed', args: {'error': '$e'})),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  void _onLocalAssetTap(AssetEntity asset) {
    if (isLocalSelecting) {
      setState(() {
        if (!selectedLocalIds.remove(asset.id)) {
          selectedLocalIds.add(asset.id);
        }
        if (selectedLocalIds.isEmpty) isLocalSelecting = false;
      });
      return;
    }
    goto(
      context,
      LocalAssetViewerPage(
        asset: asset,
        api: api,
        backup: backup,
        onUploaded: () {
          _fetchMedia();
          _fetchStats();
        },
      ),
    );
  }

  void _onLocalAssetLongPress(AssetEntity asset) {
    setState(() {
      isLocalSelecting = true;
      if (!selectedLocalIds.remove(asset.id)) {
        selectedLocalIds.add(asset.id);
      }
    });
  }

  Future<void> _uploadSelectedLocal() async {
    final assets = backup.localAssets.where((a) => selectedLocalIds.contains(a.id)).toList();
    if (assets.isEmpty || backup.isUploading) return;
    setState(() {
      selectedLocalIds.clear();
      isLocalSelecting = false;
    });
    await backup.uploadAssets(api, assets);
    if (!mounted) return;
    _fetchMedia();
    _fetchStats();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          t('local.done', args: {
            'uploaded': '${backup.completedCount}',
            'skipped': '${backup.skippedCount}',
            'failed': '${backup.failedCount}',
          }),
        ),
      ),
    );
  }

  Map<String, List<MediaItem>> _groupByDate(List<MediaItem> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final Map<String, List<MediaItem>> grouped = {};
    for (final item in items) {
      final d = DateTime(item.timestamp.year, item.timestamp.month, item.timestamp.day);
      final String label;
      if (d == today) {
        label = "Today";
      } else if (d == yesterday) {
        label = "Yesterday";
      } else {
        label = "${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}";
      }
      grouped.putIfAbsent(label, () => []).add(item);
    }
    return grouped;
  }

  @override
  void dispose() {
    backup.dispose();
    mediaScroll.dispose();
    localScroll.dispose();
    backupScroll.dispose();
    settingsScroll.dispose();
    navbarVisible.dispose();
    gridColumnsNotifier.dispose();
    urlEditController.dispose();
    tokenEditController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
        key: scaffoldKey,
        body: Stack(
          alignment: .topStart,
          children: [
            const Positioned.fill(child: AppBackground()),
            Positioned.fill(child: _buildTabStack()),
            ValueListenableBuilder<bool>(
              valueListenable: navbarVisible,
              builder: (context, visible, _) => _buildBottomNavbar(context, visible),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: navbarVisible,
              builder: (context, visible, _) => AnimatedBuilder(
                animation: backup,
                builder: (context, _) => _buildTopHeader(context, visible),
              ),
            ),
            if (_activePointers.length >= 2 && (currentTab == 0 || currentTab == 1))
              _buildPinchHud(context),
          ],
        ),
      ),
    );
  }

  /// Tab yang pernah dibuka tetap hidup (state & scroll tersimpan), tapi hanya
  /// satu yang tampil. Tab yang belum pernah dibuka tidak dibangun sama sekali.
  Widget _buildTabStack() {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final index in visitedTabs)
          Offstage(
            offstage: index != currentTab,
            child: TickerMode(
              enabled: index == currentTab,
              child: _buildTabContent(index),
            ),
          ),
      ],
    );
  }

  Widget _buildTabContent(int index) {
    switch (index) {
      case 1:
        // Rebuild hanya subtree tab ini saat progres backup / jumlah kolom berubah.
        return AnimatedBuilder(
          animation: Listenable.merge([backup, gridColumnsNotifier]),
          builder: (context, _) => _buildLocalTab(),
        );
      case 2:
        return AnimatedBuilder(
          animation: backup,
          builder: (context, _) => _buildBackupTab(),
        );
      case 3:
        return _buildSettingsTab();
      default:
        return ValueListenableBuilder<int>(
          valueListenable: gridColumnsNotifier,
          builder: (context, _, _) => _buildMediaTab(),
        );
    }
  }

  Widget _buildPinchHud(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      top: MediaQuery.of(context).padding.top + 74,
      child: IgnorePointer(
        child: Center(
          child: GlassSurface(
            radius: 18,
            blur: 18,
            opacity: 0.6,
            shadow: false,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: .min,
              children: [
                const Icon(Icons.grid_view_rounded, size: 15),
                const SizedBox(width: 6),
                ValueListenableBuilder<int>(
                  valueListenable: gridColumnsNotifier,
                  builder: (context, columns, _) => Text(
                    t('appearance.columnsValue', args: {'count': '$columns'}),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyStateCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required ScrollController scrollController,
    Widget? action,
    double topPadding = 0,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      controller: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: topPadding, left: 20, right: 20, bottom: 120),
      children: [
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary.withValues(alpha: 0.22),
                      scheme.primary.withValues(alpha: 0.05),
                    ],
                  ),
                  border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
                ),
                child: Icon(icon, size: 30, color: scheme.primary),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 18),
                action,
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMediaTab() {
    final topPad = MediaQuery.of(context).padding.top + 80;
    if (isLoadingMedia && mediaItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (mediaError != null && mediaItems.isEmpty) {
      return _emptyStateCard(
        icon: Icons.cloud_off_rounded,
        title: t('media.error.title'),
        subtitle: mediaError!,
        scrollController: mediaScroll,
        topPadding: topPad + 40,
        action: FilledButton.icon(
          onPressed: _fetchMedia,
          icon: const Icon(Icons.refresh),
          label: Text(t('action.retry')),
        ),
      );
    }
    if (mediaItems.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadInitial,
        child: _emptyStateCard(
          icon: Icons.photo_library_outlined,
          title: t('media.empty.title'),
          subtitle: t('media.empty.subtitle'),
          scrollController: mediaScroll,
          topPadding: topPad + 40,
        ),
      );
    }

    final grouped = _groupByDate(mediaItems);
    return Listener(
      onPointerDown: _handleGridPointerDown,
      onPointerMove: _handleGridPointerMove,
      onPointerUp: _handleGridPointerEnd,
      onPointerCancel: _handleGridPointerEnd,
      child: RefreshIndicator(
        onRefresh: _loadInitial,
        edgeOffset: topPad,
        child: CustomScrollView(
          controller: mediaScroll,
          physics: _gridPhysics,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: topPad + 4, left: 16, right: 16, bottom: 8),
              sliver: SliverToBoxAdapter(
                child: Text(
                  mediaTotal != null
                      ? t('media.count', args: {'count': '$mediaTotal'})
                      : t('media.countShort', args: {'count': '${mediaItems.length}'}),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            for (final entry in grouped.entries) ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: buildSectionHeader(entry.key, _groupSubtitle(entry.value)),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: gridColumns,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                    childAspectRatio: 3 / 4,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _buildMediaTile(entry.value[index]),
                    childCount: entry.value.length,
                  ),
                ),
              ),
            ],
            SliverPadding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 110),
              sliver: SliverToBoxAdapter(child: _buildMediaFooter()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalTab() {
    final topPad = MediaQuery.of(context).padding.top + 80;

    if (!backup.permissionGranted) {
      return _emptyStateCard(
        icon: Icons.lock_open_rounded,
        title: t('local.permission.title'),
        subtitle: backup.lastError ?? t('local.permission.subtitle'),
        scrollController: localScroll,
        topPadding: topPad + 40,
        action: FilledButton.icon(
          onPressed: backup.isScanning ? null : backup.scan,
          icon: const Icon(Icons.lock_open_rounded),
          label: Text(t('local.permission.cta')),
        ),
      );
    }

    if (backup.isScanning && backup.localAssets.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (backup.localAssets.isEmpty) {
      return RefreshIndicator(
        onRefresh: backup.scan,
        child: _emptyStateCard(
          icon: Icons.image_not_supported_outlined,
          title: t('local.empty.title'),
          subtitle: t('local.empty.subtitle'),
          scrollController: localScroll,
          topPadding: topPad + 40,
        ),
      );
    }

    return Stack(
      children: [
        Listener(
          onPointerDown: _handleGridPointerDown,
          onPointerMove: _handleGridPointerMove,
          onPointerUp: _handleGridPointerEnd,
          onPointerCancel: _handleGridPointerEnd,
          child: RefreshIndicator(
            onRefresh: backup.scan,
            edgeOffset: topPad,
            child: GridView.builder(
              controller: localScroll,
              physics: _gridPhysics,
              padding: EdgeInsets.only(top: topPad, left: 12, right: 12, bottom: selectedLocalIds.isEmpty ? 110 : 190),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: gridColumns,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: backup.localAssets.length,
              itemBuilder: (context, index) {
                final asset = backup.localAssets[index];
                return LocalAssetTile(
                  asset: asset,
                  selecting: isLocalSelecting,
                  selected: selectedLocalIds.contains(asset.id),
                  backedUp: backup.isBackedUp(asset.id),
                  onTap: () => _onLocalAssetTap(asset),
                  onLongPress: () => _onLocalAssetLongPress(asset),
                );
              },
            ),
          ),
        ),
        if (selectedLocalIds.isNotEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 96,
            child: GlassSurface(
              radius: 28,
              blur: 30,
              opacity: 0.62,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      selectedLocalIds.clear();
                      isLocalSelecting = false;
                    }),
                  ),
                  Text(
                    t('local.selected', args: {'count': '${selectedLocalIds.length}'}),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: backup.isUploading ? null : _uploadSelectedLocal,
                    icon: const Icon(Icons.cloud_upload_rounded, size: 18),
                    label: Text(t('action.upload')),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBackupTab() {
    final topPad = MediaQuery.of(context).padding.top + 80;
    return RefreshIndicator(
      onRefresh: () async {
        await backup.scan();
        await _fetchStats();
      },
      edgeOffset: topPad,
      child: ListView(
        controller: backupScroll,
        padding: EdgeInsets.only(top: topPad, left: 20, right: 20, bottom: 110),
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(t('backup.title'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                      if (backup.isScanning)
                        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        IconButton(
                          onPressed: backup.scan,
                          icon: const Icon(Icons.refresh_rounded),
                          tooltip: t('backup.scanTooltip'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _statTile(t('backup.localMedia'), "${backup.localAssets.length}"),
                      _statTile(t('backup.backedUp'), "${backup.backedUpCount}"),
                      _statTile(t('backup.queue'), "${backup.pendingCount}"),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (backup.isUploading) ...[
                    LinearProgressIndicator(value: backup.progress),
                    const SizedBox(height: 8),
                    Text(
                      t('backup.uploadingItem', args: {
                        'done': '${backup.completedCount + backup.failedCount}',
                        'total': '${backup.totalQueued}',
                        'name': backup.currentFileName ?? '',
                      }),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (backup.lastError != null) ...[
                    Text(
                      backup.lastError!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: backup.isScanning ? null : _toggleBackup,
                          icon: Icon(backup.isUploading ? Icons.pause_rounded : Icons.cloud_upload_rounded),
                          label: Text(backup.isUploading ? t('action.pauseBackup') : t('action.startBackup')),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: backup.isScanning || backup.isUploading ? null : backup.scan,
                        icon: const Icon(Icons.photo_library_rounded),
                        label: Text(t('backup.scan')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('backup.storageTitle'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  if (serverStats == null)
                    Text(t('backup.statsLoading'))
                  else
                    Row(
                      children: [
                        _statTile(t('backup.totalAssets'), "${serverStats!.totalCount}"),
                        _statTile(t('backup.originalSize'), formatBytes(serverStats!.totalSize)),
                        _statTile(t('backup.thumbnailSize'), formatBytes(serverStats!.thumbSize)),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statTile(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void _showLanguagePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: GlassSurface(
            radius: 30,
            blur: 34,
            opacity: 0.86,
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t('appearance.language'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(t('appearance.languageSubtitle'), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                ...l10n.languages.map((option) {
                  final selected = option.code == l10n.code;
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      await l10n.setLanguage(option.code);
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) setState(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      child: Row(
                        children: [
                          Text(option.flag, style: const TextStyle(fontSize: 20)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              option.name,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (selected)
                            Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 10),
                Text(
                  "assets/i18n/<kode>.json → assets/i18n/index.json",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsTab() {
    final topPad = MediaQuery.of(context).padding.top + 80;
    return ListView(
      controller: settingsScroll,
      padding: EdgeInsets.only(top: topPad, left: 20, right: 20, bottom: 110),
      children: [
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.blur_on_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      t('appearance.title'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _showLanguagePicker,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                    child: Row(
                      children: [
                        Icon(Icons.translate_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: .start,
                            children: [
                              Text(
                                t('appearance.language'),
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              Text(
                                t('appearance.languageSubtitle'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        Text(
                          "${l10n.current.flag} ${l10n.current.name}",
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right_rounded, size: 18),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t('appearance.accent'), style: Theme.of(context).textTheme.bodyMedium),
                    Text(accentLabel(accentById(accentId)), style: Theme.of(context).textTheme.labelLarge),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: accentOptions.map((option) {
                    final selected = option.id == accentId;
                    return GestureDetector(
                      onTap: () async {
                        setState(() => accentId = option.id);
                        accentColor.value = option.seed;
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString(accentPrefsKey, option.id);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: option.seed,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: selected ? 1 : 0.3),
                            width: selected ? 2.5 : 1,
                          ),
                          boxShadow: selected
                              ? [
                                  BoxShadow(
                                    color: option.seed.withValues(alpha: 0.5),
                                    blurRadius: 14,
                                    offset: const Offset(0, 4),
                                  ),
                                ]
                              : null,
                        ),
                        child: selected
                            ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t('appearance.blur'), style: Theme.of(context).textTheme.bodyMedium),
                    Text(
                      "${(glassBlurScale * 100).round()}%",
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ],
                ),
                Slider(
                  value: glassBlurScale,
                  min: minGlassBlurScale,
                  max: maxGlassBlurScale,
                  divisions: 10,
                  label: "${(glassBlurScale * 100).round()}%",
                  onChanged: (value) async {
                    setState(() => glassBlurScale = value);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setDouble(_blurScalePrefsKey, value);
                  },
                ),
                Text(
                  glassBlurScale <= 0.01 ? t('appearance.blurOff') : t('appearance.blurHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<int>(
                  valueListenable: gridColumnsNotifier,
                  builder: (context, columns, _) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(t('appearance.columns'), style: Theme.of(context).textTheme.bodyMedium),
                            Text(
                              t('appearance.columnsValue', args: {'count': '$columns'}),
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ],
                        ),
                        Slider(
                          value: columns.toDouble(),
                          min: 2,
                          max: 8,
                          divisions: 6,
                          label: "$columns",
                          onChanged: (value) async {
                            // Tidak memakai setState: hanya grid yang perlu rebuild.
                            gridColumnsNotifier.value = value.round();
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setInt(_gridColumnsPrefsKey, value.round());
                          },
                        ),
                      ],
                    );
                  },
                ),
                Text(
                  t('appearance.pinchHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('server.title'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: urlEditController,
                  decoration: InputDecoration(
                    labelText: t('server.url'),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenEditController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: t('server.token'),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    final newUrl = urlEditController.text.trim();
                    final newToken = tokenEditController.text.trim();
                    if (newUrl.isEmpty) return;
                    final testApi = Api(newUrl, token: newToken.isEmpty ? null : newToken);
                    try {
                      await testApi.checkServer();
                      if (newToken.isNotEmpty) await testApi.getStats();
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString("syncfony_server_url", newUrl);
                      await prefs.setString("syncfony_server_token", newToken);
                      if (!mounted) return;
                      setState(() => api = testApi);
                      backup.attachApi(testApi);
                      backup.scan();
                      _loadInitial();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t('server.saved'))),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(t('server.failed', args: {'error': '$e'})),
                          backgroundColor: Colors.red.shade800,
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.save_rounded),
                  label: Text(t('server.save')),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.sync_rounded),
                title: Text(t('server.background')),
                subtitle: Text(t('server.backgroundSubtitle')),
                value: backgroundEnabled,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(backgroundEnabledPrefsKey, value);
                  await configureBackgroundBackup(enabled: value);
                  if (!mounted) return;
                  setState(() => backgroundEnabled = value);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        value ? t('server.backgroundOn') : t('server.backgroundOff'),
                      ),
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.camera_enhance_rounded),
                title: Text(t('server.backfill')),
                subtitle: Text(t('server.backfillSubtitle')),
                trailing: isBackfilling
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                onTap: isBackfilling ? null : _backfillCameraInfo,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cleaning_services_rounded),
                title: Text(t('server.resetCache')),
                subtitle: Text(t('server.resetCacheSubtitle')),
                onTap: () async {
                  await backup.clearCache();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t('server.resetCacheDone'))),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.logout_rounded, color: Theme.of(context).colorScheme.error),
                title: Text(
                  t('server.disconnect'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => goback(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNavbar(BuildContext context, bool visible) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      bottom: visible ? (MediaQuery.of(context).padding.bottom + 20.0) : -120.0,
      left: 0,
      right: 0,
      child: Center(
        child: GlassSurface(
          radius: 34,
          blur: 30,
          opacity: 0.55,
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisSize: .min,
            children: [
              _navItem(context, index: 0, icon: Icons.perm_media_rounded, label: t('nav.media')),
              _navItem(context, index: 1, icon: Icons.phone_iphone_rounded, label: t('nav.local')),
              _navItem(context, index: 2, icon: Icons.cloud_done_rounded, label: t('nav.backup')),
              _navItem(context, index: 3, icon: Icons.settings_rounded, label: t('nav.settings')),
            ],
          ),
        ),
      ),
    );
  }

  void _selectTab(int index) {
    setState(() {
      currentTab = index;
      visitedTabs.add(index);
    });
    // Sinkronkan ulang indeks backup setiap kali tab Lokal/Backup dibuka,
    // agar hitungan mengikuti kondisi server terbaru.
    if ((index == 1 || index == 2) && !backup.isScanning && !backup.isUploading) {
      backup.scan();
    }
  }

  Widget _navItem(BuildContext context, {required int index, required IconData icon, required String label}) {
    final scheme = Theme.of(context).colorScheme;
    final active = currentTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectTab(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(horizontal: active ? 16 : 13, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: active
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary,
                    Color.alphaBlend(Colors.black.withValues(alpha: 0.16), scheme.primary),
                  ],
                )
              : null,
          boxShadow: active
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 7),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: .min,
          children: [
            Icon(icon, size: 20, color: active ? scheme.onPrimary : scheme.onSurfaceVariant),
            if (active) ...[
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTopHeader(BuildContext context, bool visible) {
    final scheme = Theme.of(context).colorScheme;
    const tabKeys = ['nav.media', 'nav.local', 'nav.backup', 'nav.settings'];
    final subtitle = backup.isUploading
        ? t('header.uploading', args: {
            'done': '${backup.completedCount + backup.failedCount}',
            'total': '${backup.totalQueued}',
          })
        : "${t(tabKeys[currentTab % tabKeys.length])} • ${shortHost(api.normalizedUrl)}";

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      top: visible ? (MediaQuery.of(context).padding.top + 6.0) : (MediaQuery.of(context).padding.top - 150.0),
      left: 14,
      right: 14,
      child: GlassSurface(
        radius: 26,
        blur: 30,
        opacity: 0.58,
        padding: const EdgeInsets.fromLTRB(10, 9, 9, 9),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: const AppLogo(size: 38),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: .start,
                    mainAxisSize: .min,
                    children: [
                      const Text(
                        "Syncfony",
                        style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, letterSpacing: -0.35),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (backup.isUploading)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      "${(backup.progress * 100).round()}%",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                GlassIconButton(
                  icon: backup.isUploading ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 40,
                  iconSize: 20,
                  active: backup.isUploading,
                  onPressed: _toggleBackup,
                  tooltip: backup.isUploading ? t('action.pauseBackup') : t('action.startBackup'),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              child: backup.isUploading
                  ? Padding(
                      padding: const EdgeInsets.only(top: 9, left: 3, right: 3),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: backup.progress > 0 ? backup.progress : null,
                          minHeight: 3.5,
                          backgroundColor: scheme.primary.withValues(alpha: 0.15),
                        ),
                      ),
                    )
                  : const SizedBox(height: 0),
            ),
          ],
        ),
      ),
    );
  }

  String _groupSubtitle(List<MediaItem> items) {
    final first = items.first.timestamp;
    return "${first.month.toString().padLeft(2, '0')}/${first.year}";
  }

  Widget _buildMediaFooter() {
    if (isLoadingMoreMedia) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (hasMoreMedia) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: TextButton.icon(
          onPressed: _loadMoreMedia,
          icon: const Icon(Icons.expand_more_rounded),
          label: Text(t('media.loadMore')),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget buildSectionHeader(String title, String subtitle) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Row(
        mainAxisAlignment: .spaceBetween,
        crossAxisAlignment: .end,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5),
          ),
          Text(
            subtitle,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _formatDuration(double seconds) {
    final total = seconds.round();
    final mins = total ~/ 60;
    final secs = total % 60;
    return "${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}";
  }

  Widget _buildMediaTile(MediaItem item) {
    final thumbUrl = item.hasThumb ? api.getThumbUrl(item.id) : api.getFileUrl(item.id);
    return GestureDetector(
      onTap: () {
        goto(
          context,
          MediaViewerPage(
            item: item,
            api: api,
            onDelete: () => _deleteMedia(item),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: .circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.35),
              child: Image.network(
                thumbUrl,
                headers: api.authHeaders,
                fit: .cover,
                cacheWidth: 400,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: Colors.white10,
                  child: Icon(
                    item.isVideo ? Icons.videocam_outlined : Icons.image_outlined,
                    color: Colors.white24,
                  ),
                ),
              ),
            ),
            if (!item.isVideo && item.hasLive)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.motion_photos_on_rounded, size: 12, color: Colors.white),
                      const SizedBox(width: 3),
                      Text(t('viewer.live'), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            if (item.isVideo)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_arrow_rounded, size: 14, color: Colors.white),
                      if (item.duration != null)
                        Text(
                          _formatDuration(item.duration!),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class LocalAssetTile extends StatefulWidget {
  final AssetEntity asset;
  final bool selecting;
  final bool selected;
  final bool backedUp;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const LocalAssetTile({
    super.key,
    required this.asset,
    required this.selecting,
    required this.selected,
    required this.backedUp,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<LocalAssetTile> createState() => _LocalAssetTileState();
}

class _LocalAssetTileState extends State<LocalAssetTile> {
  Uint8List? _thumb;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = ThumbnailCache.get(widget.asset.id);
    if (cached != null) {
      if (mounted) setState(() => _thumb = cached);
      return;
    }

    try {
      final bytes = await widget.asset.thumbnailDataWithSize(
        const ThumbnailSize.square(320),
        quality: 80,
      );
      if (bytes != null) {
        ThumbnailCache.put(widget.asset.id, bytes);
      }
      if (!mounted) return;
      setState(() => _thumb = bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final isVideo = asset.type == AssetType.video;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.35),
              child: _thumb != null
                  ? Image.memory(_thumb!, fit: BoxFit.cover, gaplessPlayback: true)
                  : Center(
                      child: _failed
                          ? Icon(
                              isVideo ? Icons.videocam_outlined : Icons.image_outlined,
                              color: Colors.white24,
                            )
                          : const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                    ),
            ),
            if (isVideo)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_arrow_rounded, size: 12, color: Colors.white),
                      Text(
                        formatClock(asset.duration),
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ),
            if (asset.isLivePhoto)
              const Positioned(
                left: 4,
                bottom: 4,
                child: Icon(Icons.motion_photos_on_rounded, size: 14, color: Colors.white),
              ),
            if (widget.backedUp)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.cloud_done_rounded, size: 13, color: Colors.white),
                ),
              ),
            if (widget.selected) Container(color: Colors.black26),
            if (widget.selecting)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: widget.selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.black38,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white70, width: 1.5),
                  ),
                  child: widget.selected
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
  'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
];

/// Menampilkan host server tanpa skema, mis. `192.168.1.10:2026`.
String shortHost(String url) {
  var value = url.trim();
  if (value.startsWith('https://')) value = value.substring(8);
  if (value.startsWith('http://')) value = value.substring(7);
  if (value.endsWith('/')) value = value.substring(0, value.length - 1);
  return value;
}

/// Nama warna aksen yang mengikuti bahasa aktif (fallback ke label bawaan).
String accentLabel(AccentOption option) {
  final key = 'color.${option.id}';
  final translated = t(key);
  return translated == key ? option.label : translated;
}

/// Mengambil daftar nama terpisah koma dari kamus bahasa, dengan fallback lokal.
List<String> localizedList(String key, List<String> fallback) {
  final raw = t(key);
  final parts = raw.split(',').map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
  return parts.length == fallback.length ? parts : fallback;
}

String formatReadableDate(DateTime dt) {
  final months = localizedList('date.months', _monthNames);
  final month = months[(dt.month - 1) % 12];
  final hour = dt.hour.toString().padLeft(2, '0');
  final minute = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} $month ${dt.year} - $hour:$minute';
}

class LocalAssetViewerPage extends StatefulWidget {
  final AssetEntity asset;
  final Api api;
  final BackupController backup;
  final VoidCallback onUploaded;

  const LocalAssetViewerPage({
    super.key,
    required this.asset,
    required this.api,
    required this.backup,
    required this.onUploaded,
  });

  @override
  State<LocalAssetViewerPage> createState() => _LocalAssetViewerPageState();
}

class _LocalAssetViewerPageState extends State<LocalAssetViewerPage> {
  File? _file;
  int? _fileSize;
  VideoPlayerController? _video;
  VideoPlayerController? _live;
  bool _loading = true;
  bool _uploading = false;
  bool _playingLive = false;
  bool _showControls = true;
  String? _error;

  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final file = await widget.asset.file;
      if (!mounted) return;
      if (file == null) {
        setState(() {
          _loading = false;
          _error = 'File tidak tersedia di perangkat';
        });
        return;
      }
      final size = await file.length();
      if (!mounted) return;
      setState(() {
        _file = file;
        _fileSize = size;
      });

      if (_isVideo) {
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        controller.addListener(_tick);
        await controller.play();
        if (!mounted) {
          controller.dispose();
          return;
        }
        setState(() {
          _video = controller;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _playLive() async {
    if (_playingLive) return;
    try {
      if (_live == null) {
        final liveFile = await widget.asset.fileWithSubtype;
        if (liveFile == null) return;
        final controller = VideoPlayerController.file(liveFile);
        await controller.initialize();
        controller.addListener(_tick);
        _live = controller;
      }
      await _live!.seekTo(Duration.zero);
      await _live!.play();
      if (mounted) setState(() => _playingLive = true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gagal memutar Live Photo')),
      );
    }
  }

  Future<void> _stopLive() async {
    if (_playingLive) {
      await _live?.pause();
    }
    if (mounted && _playingLive) setState(() => _playingLive = false);
  }

  @override
  void dispose() {
    _video?.dispose();
    _live?.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    await widget.backup.uploadAssets(widget.api, [widget.asset]);
    widget.onUploaded();
    if (!mounted) return;
    setState(() => _uploading = false);
    final skipped = widget.backup.skippedCount > 0 && widget.backup.completedCount == 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(skipped ? t('local.alreadyOnServer') : t('local.backupDone')),
      ),
    );
  }

  void _showInfo() {
    final asset = widget.asset;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: GlassSurface(
            radius: 30,
            blur: 34,
            opacity: 0.84,
            tint: const Color(0xFF0D1411),
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  formatReadableDate(asset.createDateTime),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  asset.title ?? t('viewer.noName'),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                _localInfoRow(
                  t('info.type'),
                  _isVideo
                      ? t('info.video')
                      : (asset.isLivePhoto ? t('info.livePhoto') : t('info.photo')),
                ),
                _localInfoRow(
                  'Dimensi',
                  '${asset.width} x ${asset.height}',
                ),
                _localInfoRow(
                  t('info.size'),
                  _fileSize == null ? t('info.loading') : formatBytes(_fileSize!),
                ),
                _localInfoRow(
                  asset.isLivePhoto ? t('info.livePhoto') : t('info.duration'),
                  _isVideo ? formatClock(asset.duration) : t('info.none'),
                ),
                _localInfoRow(
                  t('info.backupStatus'),
                  widget.backup.isBackedUp(asset.id) ? t('info.backedUp') : t('info.notBackedUp'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _localInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 13)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final backedUp = widget.backup.isBackedUp(asset.id);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: viewerGlassBar(),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              asset.title ?? t('viewer.localTitle'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              formatReadableDate(asset.createDateTime),
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: _showInfo,
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: (backedUp || _uploading) ? null : _upload,
            icon: _uploading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(backedUp ? Icons.cloud_done_rounded : Icons.cloud_upload_rounded),
            label: Text(
              backedUp
                  ? t('local.alreadyBackedUp')
                  : (_uploading ? t('local.uploading') : t('local.backupNow')),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (_loading || _file == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_isVideo) {
      return _buildVideo(_video);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onLongPressStart: widget.asset.isLivePhoto ? (_) => _playLive() : null,
          onLongPressEnd: widget.asset.isLivePhoto ? (_) => _stopLive() : null,
          child: Center(
            child: _playingLive && _live != null && _live!.value.isInitialized
                ? AspectRatio(
                    aspectRatio: _live!.value.aspectRatio > 0
                        ? _live!.value.aspectRatio
                        : 3 / 4,
                    child: VideoPlayer(_live!),
                  )
                : InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.file(_file!, fit: BoxFit.contain),
                  ),
          ),
        ),
        if (widget.asset.isLivePhoto)
          Positioned(
            left: 16,
            bottom: MediaQuery.of(context).padding.bottom + 90,
            child: GestureDetector(
              onTap: _playingLive ? _stopLive : _playLive,
              child: GlassSurface(
                radius: 16,
                blur: 18,
                opacity: _playingLive ? 0.95 : 0.55,
                shadow: false,
                tint: _playingLive ? Colors.white : const Color(0xFF0B1210),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.motion_photos_on_rounded,
                      size: 16,
                      color: _playingLive ? Colors.black : Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _playingLive ? t('viewer.livePlaying') : t('viewer.live'),
                      style: TextStyle(
                        color: _playingLive ? Colors.black : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVideo(VideoPlayerController? controller) {
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio > 0
                  ? controller.value.aspectRatio
                  : 16 / 9,
              child: VideoPlayer(controller),
            ),
          ),
          if (_showControls)
            Container(
              decoration: const BoxDecoration(
                color: Colors.black38,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: 56,
                color: Colors.white,
                icon: Icon(
                  controller.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
                onPressed: () {
                  if (controller.value.isPlaying) {
                    controller.pause();
                  } else {
                    controller.play();
                  }
                  setState(() {});
                },
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              colors: VideoProgressColors(
                playedColor: Theme.of(context).colorScheme.primary,
                bufferedColor: Colors.white30,
                backgroundColor: Colors.white12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MediaViewerPage extends StatefulWidget {
  final MediaItem item;
  final Api api;
  final Future<void> Function() onDelete;

  const MediaViewerPage({
    super.key,
    required this.item,
    required this.api,
    required this.onDelete,
  });

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoError = false;
  bool _isMuted = false;
  bool _showControls = true;

  VideoPlayerController? _liveController;
  bool _isPlayingLive = false;
  bool _isLoadingLive = false;

  @override
  void initState() {
    super.initState();
    if (widget.item.isVideo) {
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.api.getFileUrl(widget.item.id)),
      httpHeaders: widget.api.authHeaders,
    );
    _videoController = controller;
    try {
      await controller.initialize();
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      await controller.play();
      if (mounted) {
        setState(() => _isVideoInitialized = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isVideoError = true);
      }
    }
  }

  Future<void> _playLivePhoto() async {
    if (!widget.item.hasLive || _isPlayingLive || _isLoadingLive) return;
    setState(() => _isLoadingLive = true);
    try {
      _liveController ??= VideoPlayerController.networkUrl(
        Uri.parse(widget.api.getLiveUrl(widget.item.id)),
        httpHeaders: widget.api.authHeaders,
      );
      if (!_liveController!.value.isInitialized) {
        await _liveController!.initialize();
        _liveController!.addListener(() {
          if (!mounted) return;
          final val = _liveController!.value;
          if (val.isInitialized && !val.isPlaying && val.position >= val.duration && _isPlayingLive) {
            setState(() => _isPlayingLive = false);
          }
        });
      }
      await _liveController!.seekTo(Duration.zero);
      await _liveController!.play();
      if (mounted) {
        setState(() {
          _isLoadingLive = false;
          _isPlayingLive = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingLive = false;
          _isPlayingLive = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('viewer.liveError'))),
        );
      }
    }
  }

  Future<void> _stopLivePhoto() async {
    if (_liveController != null && _liveController!.value.isPlaying) {
      await _liveController!.pause();
    }
    if (mounted && _isPlayingLive) {
      setState(() => _isPlayingLive = false);
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _liveController?.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return "${d.inHours}:$mins:$secs";
    }
    return "$mins:$secs";
  }

  String _formatIphoneDate(DateTime dt) {
    final days = localizedList('date.days', const ["Sen", "Sel", "Rab", "Kam", "Jum", "Sab", "Min"]);
    final months = localizedList('date.months', _monthNames);
    final dayName = days[(dt.weekday - 1) % 7];
    final monthName = months[(dt.month - 1) % 12];
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return "$dayName, ${dt.day} $monthName ${dt.year} • $hh:$mm";
  }

  String _resolutionBadge(MediaItem item) {
    final w = item.width ?? 0;
    final h = item.height ?? 0;
    final maxDim = w > h ? w : h;
    if (maxDim >= 3840) return "4K";
    if (maxDim >= 1920) return "HD";
    return "";
  }

  void _showIphoneInfoSheet() {
    final item = widget.item;
    final extBadge = item.extension.toUpperCase();
    final resBadge = _resolutionBadge(item);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: GlassSurface(
            radius: 30,
            blur: 34,
            opacity: 0.84,
            tint: const Color(0xFF0D1411),
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  _formatIphoneDate(item.timestamp),
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  item.originalName,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (extBadge.isNotEmpty) _infoPill(extBadge),
                    if (item.hasLive) _infoPill(t('viewer.live'), icon: Icons.motion_photos_on_rounded),
                    if (resBadge.isNotEmpty) _infoPill(resBadge),
                    if (item.isVideo && item.duration != null)
                      _infoPill(_formatDuration(Duration(milliseconds: (item.duration! * 1000).round()))),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      _infoRow(
                        Icons.aspect_ratio_rounded,
                        t('info.dimensions'),
                        (item.width != null && item.height != null)
                            ? "${item.width} × ${item.height}${item.megapixels.isNotEmpty ? '  •  ${item.megapixels}' : ''}"
                            : t('info.unavailable'),
                      ),
                      const Divider(color: Colors.white12, height: 18),
                      _infoRow(
                        Icons.sd_storage_outlined,
                        t('info.fileSize'),
                        "${formatBytes(item.fileSize)} (Thumb ${formatBytes(item.thumbSize)})",
                      ),
                      ..._buildCameraInfoRows(item),
                      const Divider(color: Colors.white12, height: 18),
                      _infoRow(
                        Icons.perm_media_outlined,
                        t('info.mime'),
                        item.mimetype,
                      ),
                      const Divider(color: Colors.white12, height: 18),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: item.hash));
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(t('info.shaCopied'))),
                          );
                        },
                        child: _infoRow(
                          Icons.fingerprint_rounded,
                          "SHA-256",
                          item.hash.length > 16 ? "${item.hash.substring(0, 16)}..." : item.hash,
                          trailing: const Icon(Icons.copy_rounded, size: 16, color: Colors.white54),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _infoPill(String text, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCameraInfoRows(MediaItem item) {
    final rows = <Widget>[];

    void add({required IconData icon, required String label, required String value}) {
      rows.add(const Divider(color: Colors.white12, height: 18));
      rows.add(_infoRow(icon, label, value));
    }

    add(
      icon: Icons.phone_iphone_rounded,
      label: t('info.device'),
      value: item.deviceName ?? t('info.unavailable'),
    );
    add(
      icon: Icons.camera_rounded,
      label: t('info.lens'),
      value: item.lens ?? t('info.unavailable'),
    );

    final specs = <String>[];
    if (item.focalLength != null) specs.add(item.focalLength!);
    if (item.aperture != null) specs.add(item.aperture!);
    if (item.iso != null) specs.add("ISO ${item.iso}");
    if (item.exposure != null) specs.add(item.exposure!);
    if (specs.isNotEmpty) {
      add(icon: Icons.tune_rounded, label: t('info.camera'), value: specs.join("  •  "));
    }

    final software = item.software;
    if (software != null) {
      add(icon: Icons.memory_rounded, label: t('info.software'), value: software);
    }

    return rows;
  }

  Widget _infoRow(IconData icon, String label, String value, {Widget? trailing}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.white60),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 13)),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 6),
          trailing,
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: viewerGlassBar(),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.originalName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              _formatIphoneDate(item.timestamp),
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: _showIphoneInfoSheet,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(t('viewer.deleteTitle')),
                  content: const Text("File ini akan dihapus permanen dari server."),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('action.cancel'))),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('action.delete'))),
                  ],
                ),
              );
              if (confirmed == true) {
                await widget.onDelete();
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: GestureDetector(
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -300) {
            _showIphoneInfoSheet();
          }
        },
        child: item.isVideo ? _buildVideoBody() : _buildPhotoBody(),
      ),
    );
  }

  Widget _buildVideoBody() {
    if (_isVideoError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 56, color: Colors.white54),
            const SizedBox(height: 12),
            Text(t('viewer.videoError'), style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                setState(() => _isVideoError = false);
                _initVideo();
              },
              icon: const Icon(Icons.refresh),
              label: const Text("Coba Lagi"),
            ),
          ],
        ),
      );
    }

    if (!_isVideoInitialized || _videoController == null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          if (widget.item.hasThumb)
            Image.network(
              widget.api.getThumbUrl(widget.item.id),
              headers: widget.api.authHeaders,
              fit: BoxFit.contain,
            ),
          const CircularProgressIndicator(color: Colors.white),
        ],
      );
    }

    final vc = _videoController!;
    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: vc.value.aspectRatio > 0 ? vc.value.aspectRatio : 16 / 9,
              child: VideoPlayer(vc),
            ),
          ),
          if (_showControls) ...[
            Container(
              decoration: const BoxDecoration(
                color: Colors.black38,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: 56,
                color: Colors.white,
                icon: Icon(vc.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                onPressed: () {
                  vc.value.isPlaying ? vc.pause() : vc.play();
                  setState(() {});
                },
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 16,
              child: GlassSurface(
                radius: 18,
                blur: 22,
                opacity: 0.6,
                shadow: false,
                tint: const Color(0xFF0B1210),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VideoProgressIndicator(
                      vc,
                      allowScrubbing: true,
                      colors: VideoProgressColors(
                        playedColor: Theme.of(context).colorScheme.primary,
                        bufferedColor: Colors.white30,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "${_formatDuration(vc.value.position)} / ${_formatDuration(vc.value.duration)}",
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () {
                            _isMuted = !_isMuted;
                            vc.setVolume(_isMuted ? 0.0 : 1.0);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPhotoBody() {
    final item = widget.item;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onLongPressStart: item.hasLive ? (_) => _playLivePhoto() : null,
          onLongPressEnd: item.hasLive ? (_) => _stopLivePhoto() : null,
          child: Center(
            child: _isPlayingLive && _liveController != null && _liveController!.value.isInitialized
                ? AspectRatio(
                    aspectRatio: _liveController!.value.aspectRatio > 0
                        ? _liveController!.value.aspectRatio
                        : 3 / 4,
                    child: VideoPlayer(_liveController!),
                  )
                : InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.network(
                      widget.api.getFileUrl(item.id),
                      headers: widget.api.authHeaders,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const Center(child: CircularProgressIndicator());
                      },
                    ),
                  ),
          ),
        ),
        if (item.hasLive)
          Positioned(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
            left: 16,
            child: GestureDetector(
              onTap: _isPlayingLive ? _stopLivePhoto : _playLivePhoto,
              child: GlassSurface(
                radius: 16,
                blur: 18,
                opacity: _isPlayingLive ? 0.95 : 0.55,
                shadow: false,
                tint: _isPlayingLive ? Colors.white : const Color(0xFF0B1210),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isLoadingLive)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _isPlayingLive ? Colors.black : Colors.white,
                        ),
                      )
                    else
                      Icon(
                        Icons.motion_photos_on_rounded,
                        size: 16,
                        color: _isPlayingLive ? Colors.black : Colors.white,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      _isPlayingLive ? t('viewer.livePlaying') : t('viewer.live'),
                      style: TextStyle(
                        color: _isPlayingLive ? Colors.black : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
