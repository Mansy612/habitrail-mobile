// Chat profanity mask (App Store 1.2 "filter objectionable content").
//
// Applied when chat is *shown*; the stored text stays raw so reports remain
// reviewable. Each word is matched after undoing the usual tricks — case,
// stretched letters ("fuuuck"), l33t ("sh1t", "$hit"), dots or spaces between
// letters ("f.u.c.k", "f u c k"), stars ("f*ck"), accents and look-alike
// Cyrillic letters, invisible characters — and masked with asterisks of the
// same length. Words are matched whole (or by a few safe stems), so "class",
// "cocktail", "analysis" or "Scunthorpe" are left alone. Not exhaustive: a
// maintained word list or moderation service is the production step.

/// Masked anywhere inside a word ("motherfucker", "bullshit").
const _anywhere = ['fuck', 'shit', 'cunt'];

/// Masked when a word starts with them ("bitches", "porno", "wanker").
const _stems = [
  'bitch', 'whore', 'slut', 'wank', 'jizz', 'dildo', 'porn', 'blowjob',
  'handjob', 'rimjob', 'masturbat', 'orgasm', 'molest', 'douche', 'skank',
  'pedophil', 'paedophil', 'cocksuck', 'dickhead', 'asshole', 'arsehole',
  'motherf',
];

/// Masked as whole words (with an optional plural "s"/"es").
const _words = [
  // swearing + insults
  'fuk', 'fuq', 'fck', 'fcking', 'fking', 'fkn', 'fvck', 'phuck', 'fuc', 'stfu',
  'gtfo', 'wtf', 'sht', 'shyt', 'biatch', 'cvnt', 'ass', 'azz', 'dumbass',
  'jackass', 'smartass', 'butthole', 'bastard', 'bollocks', 'prick', 'twat',
  'tosser', 'dick', 'dickface', 'cock', 'piss', 'pissed', 'pissing', 'hoe',
  'thot', 'retard', 'retarded', 'spaz',
  // sexual
  'sex', 'sexy', 'sext', 'sexting', 'pegging', 'horny', 'boner', 'cum',
  'cumming', 'cumshot', 'pussy', 'pussies', 'penis', 'vagina', 'clit', 'anal',
  'anus', 'boob', 'boobies', 'tits', 'titty', 'titties', 'nude', 'nudes',
  'milf', 'hentai', 'nsfw', 'bdsm', 'threesome', 'deepthroat', 'fap',
  'fapping', 'onlyfans', 'rape', 'raped', 'raping', 'rapist', 'pedo', 'incest',
  // slurs
  'nigger', 'nigga', 'niggaz', 'fag', 'faggot', 'tranny', 'kike', 'chink',
  'spic', 'wetback', 'gook', 'beaner', 'coon', 'dyke', 'raghead', 'towelhead',
  // harassment
  'kys',
];

/// Masked as a run of whole words (for words that are fine on their own).
const _phrases = [
  ['kill', 'yourself'], ['kill', 'urself'], ['kill', 'your', 'self'],
  ['neck', 'yourself'], ['peg', 'you'], ['peg', 'u'], ['peg', 'me'],
  ['peg', 'him'], ['peg', 'her'], ['jerk', 'off'], ['jack', 'off'],
];

/// Real words that a stem or an anywhere-match would otherwise catch.
const _allowed = {
  'scunthorpe', 'shitake', 'shiitake', 'shiite', 'shiites', 'wankel',
};

// A letter may be stretched ("fuuuck"); a doubled letter needs at least two.
String _stretchy(String w) =>
    w.split('').map((c) => '${RegExp.escape(c)}+').join();

final _anywhereRe = RegExp(_anywhere.map(_stretchy).join('|'));
final _stemRe = RegExp('^(?:${_stems.map(_stretchy).join('|')})');
final _wordRe = RegExp('^(?:${_words.map(_stretchy).join('|')})(?:e?s)?\$');
final _phraseRes = [
  for (final p in _phrases) [for (final w in p) RegExp('^${_stretchy(w)}\$')],
];

// What a starred word ("f*ck", "b*tch", "f***ing") may stand for.
final _starTargets = [
  ..._words,
  for (final w in [..._anywhere, ..._stems])
    for (final end in ['', 's', 'es', 'er', 'ers', 'ed', 'in', 'ing', 'y'])
      '$w$end',
];

// Accents and look-alike (mostly Cyrillic) letters → plain Latin.
const _lookalike = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'а': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'е': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'і': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'о': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ç': 'c', 'с': 'c', 'ñ': 'n', 'р': 'p', 'у': 'y', 'х': 'x', 'к': 'k',
  'т': 't', 'в': 'b', 'н': 'h', 'м': 'm',
};

// L33t: symbols and digits standing in for letters. "1" and "|" can be an i
// or an l, so both readings are checked.
const _leet = {
  '0': 'o', '3': 'e', '4': 'a', '5': 's', '7': 't', '8': 'b',
  '@': 'a', '\$': 's', '!': 'i',
};

final _invisible = RegExp('[​-‍⁠﻿­]');
final _leetChars = RegExp(r'[\d@$!|*]');
final _hasLetter = RegExp(r'\p{L}', unicode: true);
// A word: letters, digits and stand-in symbols, optionally joined by . _ - '
final _tokenRe = RegExp(
    r"[\p{L}\p{N}@$!*|]+(?:['._\-][\p{L}\p{N}@$!*|]+)*",
    unicode: true);

class _Token {
  _Token(this.start, this.end, this.forms);
  final int start, end;
  final List<String> forms; // de-tricked readings (lowercase, joiners removed)
}

/// The word's possible plain readings. L33t is only undone when the word
/// also has real letters, so a score like "455 XP" stays a number.
List<String> _readings(String raw) {
  final lower = raw.toLowerCase();
  final leet = _hasLetter.hasMatch(lower.replaceAll(_leetChars, ''));
  String read(String one) {
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      if ("'._-".contains(ch)) continue;
      final c = _lookalike[ch] ?? ch;
      b.write(!leet ? c : (c == '1' || c == '|') ? one : (_leet[c] ?? c));
    }
    return b.toString();
  }

  final i = read('i');
  return leet && (lower.contains('1') || lower.contains('|')) ? [i, read('l')] : [i];
}

bool _blocked(String w) {
  if (w.isEmpty || _allowed.contains(w)) return false;
  if (w.contains('*')) return _starBlocked(w);
  return _wordRe.hasMatch(w) || _stemRe.hasMatch(w) || _anywhereRe.hasMatch(w);
}

// Each star stands for one letter of a listed word.
bool _starBlocked(String w) {
  if (w.length < 3 || w.replaceAll('*', '').isEmpty) return false;
  final re = RegExp(
      '^${w.split('').map((c) => c == '*' ? '.' : RegExp.escape(c)).join()}\$');
  return _starTargets.any(re.hasMatch);
}

// A trailing "!" or "|" is punctuation ("you!"), not a l33t letter.
int _trimEnd(String s, int start, int end) {
  while (end - start > 1 && '!|'.contains(s[end - 1])) {
    end--;
  }
  return end;
}

/// Replace objectionable words with asterisks of the same length.
String maskProfanity(String text) {
  if (text.isEmpty) return text;
  final src = text.replaceAll(_invisible, '');
  final tokens = <_Token>[];
  for (final m in _tokenRe.allMatches(src)) {
    final end = _trimEnd(src, m.start, m.end);
    tokens.add(_Token(m.start, end, _readings(src.substring(m.start, end))));
  }
  final mask = List<bool>.filled(src.length, false);
  void hide(int from, int to) {
    for (var i = from; i < to; i++) {
      if (src[i].trim().isNotEmpty) mask[i] = true;
    }
  }

  for (final t in tokens) {
    if (t.forms.any(_blocked)) hide(t.start, t.end);
  }
  // Letters spaced apart: "f u c k", "s h i t".
  for (var i = 0; i < tokens.length; i++) {
    var j = i;
    while (j + 1 < tokens.length &&
        tokens[j].forms.first.length == 1 &&
        tokens[j + 1].forms.first.length == 1 &&
        tokens[j + 1].start - tokens[j].end <= 2) {
      j++;
    }
    if (j - i >= 2) {
      final joined = tokens.sublist(i, j + 1).map((t) => t.forms.first).join();
      if (_blocked(joined)) hide(tokens[i].start, tokens[j].end);
      i = j;
    }
  }
  // Phrases: "kill yourself", "peg you".
  for (var i = 0; i < tokens.length; i++) {
    for (final p in _phraseRes) {
      if (i + p.length > tokens.length) continue;
      var hit = true;
      for (var k = 0; k < p.length && hit; k++) {
        hit = tokens[i + k].forms.any(p[k].hasMatch);
      }
      if (hit) hide(tokens[i].start, tokens[i + p.length - 1].end);
    }
  }
  if (!mask.contains(true)) return src;
  final b = StringBuffer();
  for (var i = 0; i < src.length; i++) {
    b.write(mask[i] ? '*' : src[i]);
  }
  return b.toString();
}
