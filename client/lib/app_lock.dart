import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kunci aplikasi berbasis biometrik / kredensial perangkat.
class AppLock {
  AppLock._();

  static const String prefsKey = 'syncfony_app_lock';
  static final LocalAuthentication _auth = LocalAuthentication();

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, value);
  }

  static Future<bool> canAuthenticate() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported || canCheck;
    } catch (_) {
      return false;
    }
  }

  /// Meminta autentikasi. `biometricOnly: false` agar pengguna tetap bisa
  /// memakai PIN/pola/kata sandi perangkat bila biometrik gagal.
  static Future<bool> authenticate() async {
    try {
      if (!await canAuthenticate()) return false;
      return await _auth.authenticate(
        localizedReason: 'Buka Syncfony',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

/// Status aktif/tidaknya kunci aplikasi, dipakai bersama oleh root app
/// dan halaman Settings.
final ValueNotifier<bool> appLockEnabled = ValueNotifier(false);
