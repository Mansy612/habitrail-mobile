import 'package:flutter_test/flutter_test.dart';
import 'package:habitrail/ai.dart';

void main() {
  group('heuristicEmoji', () {
    test('maps common habits to a fitting emoji', () {
      expect(heuristicEmoji('Morning run'), '🏃');
      expect(heuristicEmoji('Drink water'), '💧');
      expect(heuristicEmoji('Read 10 pages'), '📖');
      expect(heuristicEmoji('Meditate 10 min'), '🧘');
      expect(heuristicEmoji('Hit the gym'), '🏋️');
      expect(heuristicEmoji('Save money'), '💰');
    });

    test('is case-insensitive', () {
      expect(heuristicEmoji('READ a book'), '📖');
    });

    test('falls back to a generic emoji for unknown habits', () {
      expect(heuristicEmoji('Zorblatt the fnord'), '✨');
    });

    test('always returns a non-empty emoji for non-empty input', () {
      for (final h in ['x', 'Practice guitar', 'Floss', 'Call mom']) {
        expect(heuristicEmoji(h).isNotEmpty, isTrue);
      }
    });
  });
}
