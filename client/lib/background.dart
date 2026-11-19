import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'service.dart';

/// Identifier tugas background. Di iOS nilai ini harus terdaftar di
/// `BGTaskSchedulerPermittedIdentifiers` pada `Info.plist`.
const String backgroundBackupTask = 'com.syncfony.backup';

const String serverUrlPrefsKey = 'syncfony_server_url';
const String serverTokenPrefsKey = 'syncfony_server_token';
const String backgroundEnabledPrefsKey = 'syncfony_background_backup_enabled';

/// Jumlah maksimum item yang diunggah dalam satu siklus background.
const int backgroundBatchSize = 200;

/// Entry point isolate background. Wajib top-level + `vm:entry-point`
/// agar bisa dipanggil dari native.
@pragma('vm:entry-point')
void syncfonyCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString(serverUrlPrefsKey);
      if (url == null || url.trim().isEmpty) {
        return true;
      }

      final token = prefs.getString(serverTokenPrefsKey);
      final api = Api(
        url,
        token: (token == null || token.trim().isEmpty) ? null : token,
      );

      final controller = BackupController();
      controller.attachApi(api);
      // Background service tidak punya konteks Activity/ViewController.
      await PhotoManager.setIgnorePermissionCheck(true);
      await controller.scan(requestPermissions: false);
      await controller.startBackup(
        api,
        maxItems: backgroundBatchSize,
        requestPermissions: false,
      );
      controller.dispose();
      return true;
    } catch (error) {
      debugPrint('Syncfony: background backup gagal: $error');
      // false membuat WorkManager menjadwalkan ulang sesuai policy.
      return false;
    }
  });
}

/// Mendaftarkan / membatalkan tugas backup periodik.
Future<void> configureBackgroundBackup({required bool enabled}) async {
  try {
    await Workmanager().initialize(syncfonyCallbackDispatcher);
    if (!enabled) {
      await Workmanager().cancelByUniqueName(backgroundBackupTask);
      return;
    }
    await Workmanager().registerPeriodicTask(
      backgroundBackupTask,
      backgroundBackupTask,
      frequency: const Duration(minutes: 30),
      initialDelay: const Duration(minutes: 5),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (error) {
    // Simulator iOS / perangkat tanpa dukungan background akan masuk ke sini.
    debugPrint('Syncfony: konfigurasi background backup gagal: $error');
  }
}
