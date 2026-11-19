import 'dart:collection';
import 'dart:typed_data';

/// Cache LRU kecil untuk thumbnail galeri lokal.
///
/// Tujuan: tile yang di-recycle oleh grid (atau tab yang ditutup/buka) tidak
/// memanggil `thumbnailDataWithSize` (platform channel) berulang kali.
class ThumbnailCache {
  ThumbnailCache._();

  static const int maxEntries = 400;
  static final LinkedHashMap<String, Uint8List> _items = LinkedHashMap();

  static Uint8List? get(String key) {
    final value = _items.remove(key);
    if (value != null) {
      // Pindahkan ke akhir supaya dianggap paling baru dipakai.
      _items[key] = value;
    }
    return value;
  }

  static void put(String key, Uint8List value) {
    _items.remove(key);
    _items[key] = value;
    while (_items.length > maxEntries) {
      _items.remove(_items.keys.first);
    }
  }

  static void clear() {
    _items.clear();
  }
}
