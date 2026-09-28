import 'package:flutter_test/flutter_test.dart';
import 'package:stock_spheres/main.dart';

void main() {
  testWidgets('Stock Spheres app loads', (WidgetTester tester) async {
    await tester.pumpWidget(const StockSpheresApp());
    expect(find.byType(StockSpheresApp), findsOneWidget);
  });
}
