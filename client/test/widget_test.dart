import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfony/main.dart';

void main() {
  testWidgets('layar welcome tampil saat server belum dikonfigurasi', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const App());
    await tester.pump();

    // Logo/judul aplikasi ada di layar pembuka.
    expect(find.text('Syncfony'), findsWidgets);
  });
}
