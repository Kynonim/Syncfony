import 'dart:convert';
import 'dart:ui' show Locale;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Satu pilihan bahasa yang terdaftar di `assets/i18n/index.json`.
class LanguageOption {
  final String code;
  final String name;
  final String flag;

  const LanguageOption(this.code, this.name, this.flag);
}

/// Pemuatan kamus bahasa dari aset JSON.
///
/// Struktur file:
/// `assets/i18n/index.json`  -> daftar bahasa + kode default
/// `assets/i18n/<kode>.json` -> kamus `"kunci": "teks"`
class L10nController extends ChangeNotifier {
  static const String prefsKey = 'syncfony_language';
  static const String _assetDir = 'assets/i18n';

  Map<String, String> _strings = {};
  Map<String, String> _fallback = {};
  String _code = 'id';

  List<LanguageOption> languages = const [];
  String defaultCode = 'id'; //bahasa default di set ke indo

  String get code => _code;
  Locale get locale => Locale(_code);
  Map<String, String> get strings => _strings;
  Map<String, String> get fallback => _fallback;
  bool get isReady => _strings.isNotEmpty;

  LanguageOption get current {
    return languages.firstWhere(
      (option) => option.code == _code,
      orElse: () => LanguageOption(_code, _code, ''),
    );
  }

  Future<void> load() async {
    try {
      final rawIndex = await rootBundle.loadString('$_assetDir/index.json');
      final index = jsonDecode(rawIndex) as Map<String, dynamic>;
      defaultCode = (index['default'] ?? 'id').toString();
      languages = ((index['languages'] as List?) ?? [])
          .whereType<Map>()
          .map((entry) => LanguageOption(
                entry['code'].toString(),
                entry['name'].toString(),
                (entry['flag'] ?? '').toString(),
              ))
          .toList();
    } catch (error) {
      debugPrint('Syncfony: gagal membaca index bahasa: $error');
    }

    if (languages.isEmpty) {
      languages = [LanguageOption(defaultCode, defaultCode, '')];
    }

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(prefsKey);
    _code = languages.any((option) => option.code == saved) ? saved! : defaultCode;

    _fallback = await _readFile(defaultCode);
    _strings = _code == defaultCode ? _fallback : await _readFile(_code);
    notifyListeners();
  }

  Future<Map<String, String>> _readFile(String code) async {
    try {
      final raw = await rootBundle.loadString('$_assetDir/$code.json');
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((key, value) => MapEntry(key, value.toString()));
    } catch (error) {
      debugPrint('Syncfony: kamus bahasa "$code" tidak terbaca: $error');
      return {};
    }
  }

  Future<void> setLanguage(String code) async {
    if (code == _code) return;
    _code = code;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, code);

    _strings = code == defaultCode ? _fallback : await _readFile(code);
    if (_strings.isEmpty) {
      // File bahasa belum ada / rusak -> tetap pakai kamus default.
      _strings = _fallback;
    }
    notifyListeners();
  }
}

final L10nController l10n = L10nController();

/// Menerjemahkan [key].
///
/// Urutan pencarian: bahasa aktif -> bahasa default -> key itu sendiri.
/// Placeholder ditulis `{nama}` dan diisi lewat [args].
String t(String key, {Map<String, String>? args}) {
  var value = l10n.strings[key] ?? l10n.fallback[key] ?? key;
  if (args != null && args.isNotEmpty) {
    args.forEach((name, replacement) {
      value = value.replaceAll('{$name}', replacement);
    });
  }
  return value;
}
