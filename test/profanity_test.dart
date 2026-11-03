import 'package:flutter_test/flutter_test.dart';
import 'package:habitrail/profanity.dart';

void main() {
  group('masks', () {
    test('the messages that slipped through before', () {
      expect(maskProfanity('sex'), '***');
      expect(maskProfanity('I want to have sex with you'),
          'I want to have *** with you');
      expect(maskProfanity('I will peg you'), 'I will *** ***');
      expect(maskProfanity('fuck you'), '**** you');
      expect(maskProfanity('what the fuck'), 'what the ****');
    });

    test('keeps the rest of the message, length and punctuation', () {
      expect(maskProfanity("you're a bitch!"), "you're a *****!");
      expect(maskProfanity('Shit. That hurt.'), '****. That hurt.');
      expect(maskProfanity('Yo Yo'), 'Yo Yo');
    });

    test('word endings and compounds', () {
      for (final w in ['fucking', 'fucker', 'motherfucker', 'bullshit',
          'shitty', 'bitches', 'whores', 'sluts', 'porno', 'wanker',
          'assholes', 'dickhead', 'cocksucker', 'pegging']) {
        expect(maskProfanity(w), '*' * w.length, reason: w);
      }
    });

    test('caps, stretched letters, l33t and look-alikes', () {
      for (final w in ['FUCK', 'FuCk', 'fuuuuck', 'shiiiit', 'sh!t', r'$hit',
          'sh1t', 'b1tch', 's1ut', 'a55', '@ss', 'fück', 'fuсk' /* Cyrillic с */,
          'f*ck', 'b*tch', 's**t', 'f***ing', 'fvck', 'phuck', 'stfu']) {
        expect(maskProfanity(w), '*' * w.length, reason: w);
      }
    });

    test('letters split by dots, dashes, spaces or invisible characters', () {
      expect(maskProfanity('f.u.c.k off'), '******* off');
      expect(maskProfanity('f-u-c-k'), '*******');
      expect(maskProfanity('f u c k you'), '* * * * you');
      expect(maskProfanity('s h i t'), '* * * *');
      expect(maskProfanity('fu​ck'), '****');
    });

    test('sexual words, slurs and harassment', () {
      for (final s in ['send nudes', 'so horny', 'nice tits', 'kys',
          'go kill yourself', 'kill urself', 'jerk off', 'you retard',
          'sexting', 'rapist']) {
        expect(maskProfanity(s), isNot(s), reason: s);
      }
      expect(maskProfanity('just kys'), 'just ***');
      expect(maskProfanity('go kill yourself'), 'go **** ********');
    });
  });

  group('leaves alone', () {
    test('innocent words that contain or resemble a listed one', () {
      for (final s in [
        'Great class today', 'My assistant passed the assessment',
        'A cocktail in the cockpit', 'Scunthorpe United', 'data analysis',
        'cumulative score', 'the book title', 'grape juice', 'my therapist',
        'a trip to Niger', 'shiitake mushrooms', "Shi'ite and Shiite",
        'Essex and Sussex', 'a sextant', 'a Dickens novel', 'peg the tent',
        'I assume so', 'Mitsubishi', 'skyscraper', 'the Wankel engine',
        'Penistone', 'glasses', 'assassin', 'spice', 'Hancock',
      ]) {
        expect(maskProfanity(s), s, reason: s);
      }
    });

    test('numbers, symbols and ordinary punctuation', () {
      for (final s in ['I earned 455 XP!', '5*3=15', '**bold**',
          "I'm 100% sure", 'hello!!!', 'e-mail me', 'well-being', 'I a m',
          'U S A', '']) {
        expect(maskProfanity(s), s, reason: s);
      }
    });
  });
}
