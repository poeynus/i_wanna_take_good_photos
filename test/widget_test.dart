import 'package:flutter_test/flutter_test.dart';
import 'package:i_wanna_take_good_photos/main.dart';

void main() {
  testWidgets('Explains that the camera requires a mobile device', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Android 또는 iOS 기기에서 카메라를 사용할 수 있어요.'), findsOneWidget);
  });
}
