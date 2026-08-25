/// Canonical S-expression codec — the Aiko wire format.
///
/// Faithful Dart port of `aiko_services/main/utilities/parser.py`
/// (`generate` / `parse`, documented inverses). This is the substrate every
/// actor boundary rides: a remote call, an EC state delta, and a discovery
/// message are all `(command arg1 arg2 ...)` strings on this codec. See
/// `docs/distributed-seam.html` for why nothing but these strings ever crosses
/// an actor boundary.
///
/// The tree model mirrors Python's dynamic types 1:1 so interop is exact:
///   * atom      -> [String]
///   * null      -> [Null]   (encoded on the wire as `0:`)
///   * list      -> [List<Object?>]
///   * dictionary-> [Map<String, Object?>]  (keyword/value pairs `k: v`)
///
/// Correctness is pinned against golden vectors generated FROM the Python
/// reference (`tool/generate_codec_fixtures.py`), not against this codec's own
/// inverse — a self-consistent codec can be self-consistently wrong.
library;

// ─────────────────────────────────────────────────────────────────────────
// generate — build a canonical S-expression from a command + parameters.
// ─────────────────────────────────────────────────────────────────────────

/// An element gets length-prefixed (`len:data`) when it begins with a
/// canonical `digits:` marker or contains whitespace/parens — exactly
/// parser.py's `RE_DELIMITERS`.
/// Whether [element] must be emitted as a length-prefixed canonical symbol —
/// `parser.py`'s `RE_DELIMITERS = ^\d+:|[\s()]`, decided without a regex.
///
/// The character class is spelled out rather than delegated to Dart's `\s`,
/// because the two languages disagree about what whitespace is and the wire
/// format is defined by the Python reference:
///
///   * Dart's `\s` contains U+FEFF; Python's does not, so the old regex added
///     a length prefix the reference would not have.
///   * Python's `\s` contains U+0085 and U+001C-U+001F; Dart's does not, so
///     the old regex omitted a prefix the reference would have added.
///
/// Neither tokeniser SPLITS on those characters (both split on exactly space,
/// tab and newline), so the divergence never corrupted a round-trip — it made
/// the two implementations emit different bytes for the same input, which
/// matters to anything that hashes, signs or compares wire bytes, and to
/// RFC-0001 conformance. Found by differential-fuzzing 30k random atoms
/// against the reference; see benchmark/ReadMe.md.
bool _needsLengthPrefix(String element) {
  for (var i = 0; i < element.length; i++) {
    final c = element.codeUnitAt(i);
    if (c <= 0x20) {
      // 0x09-0x0d (tab, LF, VT, FF, CR), 0x1c-0x20 (the C0 separators and
      // space). Everything else below 0x20 is an ordinary atom character.
      if ((c >= 0x09 && c <= 0x0d) || (c >= 0x1c && c <= 0x20)) return true;
    } else if (c == _cOpen || c == _cClose) {
      return true;
    } else if (c >= 0x85) {
      if (c == 0x85 ||
          c == 0xa0 ||
          c == 0x1680 ||
          (c >= 0x2000 && c <= 0x200a) ||
          c == 0x2028 ||
          c == 0x2029 ||
          c == 0x202f ||
          c == 0x205f ||
          c == 0x3000) {
        return true;
      }
    }
    // The `^\d+:` alternative: a run of ASCII digits anchored at the start,
    // terminated by a colon. Only reachable while every preceding character
    // has been a digit.
    if (c == _cColon && i > 0) {
      var allDigits = true;
      for (var d = 0; d < i; d++) {
        final u = element.codeUnitAt(d);
        if (u < _c0 || u > _c9) {
          allDigits = false;
          break;
        }
      }
      if (allDigits) return true;
    }
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────
// Code-point stepping — the SINGLE definition of "one Unicode code point",
// shared by encode (length counting) and decode (symbol walking) so the two
// sides can never drift back into the UTF-16-vs-code-point split that once
// corrupted every astral character on the wire (82481b5).
// ─────────────────────────────────────────────────────────────────────────

/// UTF-16 index just past the one code point that begins at [i].
///
/// A high surrogate is paired with a *following low surrogate* into one code
/// point of two units; every other unit — including a LONE surrogate — is one
/// code point of one unit (matching `String.runes` and Python `len`).
int _codePointEnd(String s, int i) {
  final unit = s.codeUnitAt(i);
  final isPair = (unit & 0xFC00) == 0xD800 &&
      i + 1 < s.length &&
      (s.codeUnitAt(i + 1) & 0xFC00) == 0xDC00;
  return i + (isPair ? 2 : 1);
}

/// Number of Unicode code points in [s] — Python `len(str)` semantics, the
/// count the wire length prefix MUST use.
int _codePointCount(String s) {
  var n = 0;
  for (var i = 0; i < s.length; i = _codePointEnd(s, i)) {
    n++;
  }
  return n;
}

/// Port of `parser.py:generate(command, parameters)`.
///
/// [parameters] is a `List<Object?>` of positional args, or a
/// `Map<String, Object?>` of keyword args (flattened to `k: v` pairs).
String generate(String command, Object parameters) {
  final List<Object?> params;
  if (parameters is Map) {
    params = _dictToList(parameters);
  } else if (parameters is List) {
    params = parameters;
  } else {
    throw ArgumentError(
        'parameters must be a List or Map, got ${parameters.runtimeType}');
  }
  return _generateSExpression(<Object?>[command, ...params]);
}

/// Port of `generate_dict_to_list`: `{a: 1, b: 2}` -> `[a:, 1, b:, 2]`.
List<Object?> _dictToList(Map<Object?, Object?> expression) {
  final result = <Object?>[];
  expression.forEach((keyword, value) {
    result.add('$keyword:');
    result.add(value);
  });
  return result;
}

/// Port of `generate_s_expression`. The element-rewriting order (delimiter
/// check, then dict, then list, then empty-string, then null) matches the
/// Python line-for-line so edge cases like `""` and `0:` encode identically.
String _generateSExpression(List<Object?> expression) {
  final buffer = StringBuffer();
  _writeSExpression(buffer, expression);
  return buffer.toString();
}

/// Writes into a caller-supplied buffer so a nested list appends in place
/// rather than building its own String for the parent to concatenate — the
/// same quadratic accumulation the tokeniser had, once per nesting level.
void _writeSExpression(StringBuffer buffer, List<Object?> expression) {
  var character = '';
  buffer.write('(');
  for (var element in expression) {
    if (element is String && _needsLengthPrefix(element)) {
      // Length counts Unicode CODE POINTS (Python len semantics), not UTF-16
      // code units — `a 😀` is `3:a 😀`, never `4:`. Divergence here silently
      // corrupts astral-plane characters on the wire (probed 2026-07-18). The
      // count comes from the SAME stepper the decoder walks with (_codePointEnd).
      element = '${_codePointCount(element)}:$element';
    }
    if (element is Map) {
      element = _dictToList(element);
    }
    if (element is List) {
      buffer.write(character);
      _writeSExpression(buffer, element);
      character = ' ';
      continue;
    }
    if (element is String && element == '') {
      character = ' ""';
    }
    element ??= '0:';
    buffer.write(character);
    buffer.write(element);
    character = ' ';
  }
  buffer.write(')');
}

// ─────────────────────────────────────────────────────────────────────────
// parse — decode a canonical S-expression into (command, cdr).
// ─────────────────────────────────────────────────────────────────────────

// Code units for the delimiter/prefix dispatch in `_parseTokens`. Comparing
// ints avoids the one-character String that `s[i]` allocates per character.
const _c0 = 0x30, _c9 = 0x39, _cColon = 0x3a;
const _cQuote = 0x22, _cApos = 0x27;
const _cOpen = 0x28, _cClose = 0x29;
const _cSpace = 0x20, _cTab = 0x09, _cNewline = 0x0a;

/// Quoted string: `"text"` or `'text'`, non-greedy (mirrors parser.py
/// `RE_STRING`). Group 2 is the content.
final RegExp _reString = RegExp('''(['"])(.*?)\\1''');

/// Port of `parser.py:parse(payload)` with `car_cdr=True, dictionaries_flag=
/// True` (the framework's only call convention). Returns `(command, cdr)`
/// where `cdr` is a `List<Object?>` of positional args or a
/// `Map<String, Object?>` of keyword args.
(String, Object) parse(String payload) {
  final (tree, _) = _parseTokens(payload, 0);

  // car/cdr split — mirrors parser.py's tail. The whole payload is one wrapped
  // `(...)`, so `tree` is a single-element list holding the inner list.
  var car = '';
  Object cdr = <Object?>[];
  if (tree.isNotEmpty) {
    final head = tree[0];
    if (head is String) {
      car = head;
    } else if (head is List && head.isNotEmpty) {
      final command = head[0];
      // The reference is dynamically typed, so its `car` can come back as a
      // String, as `None` (a `0:` in command position) or as a nested List
      // (`((a b) c)`). Dart's return type admits only the first, and the two
      // others failed in the worst available ways: the List crashed the cast
      // with a raw TypeError -- escaping the documented "decodes, or throws
      // FormatException" contract on untrusted wire input -- and the null was
      // silently flattened to '', conflating "no command" with "empty
      // command". Both found by differential-fuzzing parse() against the
      // reference (tool/fuzz_parse_parity.dart): 103 crashes, 579 wrong values.
      //
      // We reject instead of widening the return type. A command names a
      // method to dispatch, and every reference sender builds one with
      // `generate(method_name, ...)` where method_name is a str, so no
      // conformant encoder can emit either shape. Rejecting is fail-closed at
      // a trust boundary; widening to `Object?` would push the same type
      // confusion into every caller. RFC-0001 section 8.6 records this as a
      // deliberate receive-side divergence.
      if (command is! String) {
        throw FormatException(
            'S-expression command must be a symbol, got '
            '${command == null ? 'null (0:)' : command.runtimeType}',
            payload);
      }
      car = command;
      cdr = head.sublist(1);
    }
  }
  return (car, _listToDict(cdr));
}

/// Index-based port of parser.py's recursive tokeniser. Parses atoms until a
/// matching `)` (returning one past it) or end of input. A `(` recurses to a
/// nested list with [mustClose] set: a nested frame that reaches end of input
/// without its `)` is unterminated and MUST reject cleanly (RFC-0001 §8.1),
/// where the reference implementation instead crashes with an internal
/// `TypeError`. Only the top-level frame (which sits *after* the outer `)`) is
/// allowed to reach end of input.
(List<Object?>, int) _parseTokens(String s, int start,
    {bool mustClose = false}) {
  final result = <Object?>[];
  // A bare token is normally the contiguous run `s[tokenStart..i]`, so it costs
  // one substring at flush time instead of a fresh String per character. The
  // exception is a nested `(...)` mid-token (`ab(x)cd` yields the atom `abcd`
  // *after* the sublist, per parser.py): that splits the run, so the prefix is
  // materialised into [tokenCarried] and the index restarts. No token in
  // progress <=> `tokenCarried == null && tokenStart < 0`.
  var tokenStart = -1;
  String? tokenCarried;
  var i = start;
  final n = s.length;

  // NB: deliberately no `hasToken()`/`flushToken()` closures. They would
  // capture the mutable `i`/`tokenStart`, forcing Dart to box them into a heap
  // context object that every read in this per-character loop then loads
  // through. The duplicated conditions below are the cost of keeping both
  // counters in registers.
  while (i < n) {
    if (tokenCarried == null && tokenStart < 0) {
      // `_reCanonical` (`(\d+):`) can only match on an ASCII digit, so scan for
      // it directly rather than paying a regex dispatch + `Match` allocation at
      // every token-start position. Dart's `\d` is ASCII-only, so this is exact.
      var digitEnd = i;
      while (digitEnd < n) {
        final d = s.codeUnitAt(digitEnd);
        if (d < _c0 || d > _c9) break;
        digitEnd++;
      }
      // `digitEnd + 1 < n` reproduces the `(.+)` in the reference's
      // `^(\d+):(.+)`: a canonical symbol requires at least one character
      // AFTER the colon, so a trailing `0:` or `12:` at end of input is not a
      // canonical symbol at all -- it is the ordinary atom "0:" / "12:".
      // Inside a payload the closing `)` supplies that character, which is why
      // `(ping 0:)` still decodes to null. Dropping this made a bare `0:`
      // decode as null and a bare `12:` throw, where the reference returns an
      // atom for both (differential fuzz, tool/fuzz_parse_parity.dart).
      if (digitEnd > i &&
          digitEnd + 1 < n &&
          s.codeUnitAt(digitEnd) == _cColon) {
        // A run long enough to overflow a 64-bit int must still throw the
        // FormatException `int.parse` used to throw, so defer to it there.
        var len = 0;
        if (digitEnd - i > 18) {
          len = int.parse(s.substring(i, digitEnd));
        } else {
          for (var d = i; d < digitEnd; d++) {
            len = len * 10 + (s.codeUnitAt(d) - _c0);
          }
        }
        final dataStart = digitEnd + 1;
        if (len == 0) {
          result.add(null); // `0:` encodes null
          i = dataStart;
        } else {
          // Consume `len` CODE POINTS (Python slice semantics) via the SAME
          // stepper the encoder counts with (_codePointEnd): a surrogate PAIR
          // is one code point, a LONE surrogate is its own code point — so
          // advancing 2 past `high + ')'` can never swallow the delimiter and
          // corrupt list structure.
          var end = dataStart;
          for (var taken = 0; taken < len; taken++) {
            if (end >= s.length) {
              throw FormatException(
                  'Canonical symbol length $len exceeds remaining input', s, i);
            }
            end = _codePointEnd(s, end);
          }
          result.add(s.substring(dataStart, end));
          i = end;
        }
        continue;
      }
      // `_reString` can only match on an opening quote, so gate the regex on
      // one integer compare. Anything else falls through to the delimiter
      // dispatch below -- it must NOT shortcut to the bare-atom path, or `(`,
      // `)` and whitespace get absorbed into the atom.
      final q = s.codeUnitAt(i);
      if (q == _cQuote || q == _cApos) {
        final quoted = _reString.matchAsPrefix(s, i);
        if (quoted != null) {
          result.add(quoted.group(2));
          i += quoted.group(0)!.length;
          continue;
        }
      }
    }
    final c = s.codeUnitAt(i);
    if (c == _cOpen) {
      if (tokenStart >= 0) {
        tokenCarried = (tokenCarried ?? '') + s.substring(tokenStart, i);
        tokenStart = -1;
      }
      final (sublist, j) = _parseTokens(s, i + 1, mustClose: true);
      i = j;
      result.add(sublist);
    } else if (c == _cClose) {
      if (tokenCarried != null || tokenStart >= 0) {
        result.add((tokenCarried ?? '') +
            (tokenStart < 0 ? '' : s.substring(tokenStart, i)));
      }
      return (result, i + 1);
    } else if (c == _cSpace || c == _cTab || c == _cNewline) {
      if (tokenCarried != null || tokenStart >= 0) {
        result.add((tokenCarried ?? '') +
            (tokenStart < 0 ? '' : s.substring(tokenStart, i)));
        tokenCarried = null;
        tokenStart = -1;
      }
      i++;
    } else {
      if (tokenStart < 0) tokenStart = i;
      i++;
    }
  }
  if (mustClose) {
    throw FormatException(
        'Unterminated list: expected ")" before end of input', s, s.length);
  }
  if (tokenCarried != null || tokenStart >= 0) {
    result.add((tokenCarried ?? '') +
        (tokenStart < 0 ? '' : s.substring(tokenStart, i)));
  }
  return (result, i);
}

/// Port of `parse_list_to_dict`: a list whose first element is a non-empty
/// String ending in `:` is a keyword dictionary; otherwise it stays a list
/// (recursively converting nested lists). Keeps `null` and atoms as-is.
Object _listToDict(Object tree) {
  if (tree is! List<Object?> || tree.isEmpty) return tree;
  final head = tree[0];
  if (head is String && head.isNotEmpty && head.endsWith(':')) {
    if (tree.length.isOdd) {
      throw FormatException(
          'S-expression dictionary starting at "$head" must have pairs of '
          'keywords and values');
    }
    final map = <String, Object?>{};
    for (var i = 0; i < tree.length ~/ 2; i++) {
      // Every even-indexed element is a keyword: it MUST be a string ending in
      // `:` (parser.py parse_list_to_dict raises ValueError otherwise). Without
      // these guards a mixed positional+keyword payload like `(c a: 1 b c: 2 d)`
      // silently strips the last char off `b`/`2`, colliding empty keys into a
      // structurally-plausible-but-wrong dict instead of rejecting.
      final keyword = tree[i * 2];
      if (keyword is! String) {
        throw FormatException(
            'S-expression dictionary keyword "$keyword" must be a string');
      }
      // Faithful to parser.py: the `:` check is skipped for an empty keyword
      // (its `len()` guard), which then maps to the empty key.
      if (keyword.isNotEmpty && !keyword.endsWith(':')) {
        throw FormatException(
            'S-expression dictionary keyword "$keyword" must end with ":"');
      }
      final value = tree[i * 2 + 1];
      final key =
          keyword.isEmpty ? '' : keyword.substring(0, keyword.length - 1);
      map[key] = value == null ? null : _listToDict(value);
    }
    return map;
  }
  // Copy-on-write: the old unconditional rebuild allocated a fresh List for
  // EVERY list in the tree, including the common case of a list of plain atoms
  // where nothing changes. `_listToDict` returns its argument unchanged for
  // anything that is not a keyword list, so an identity check tells us whether
  // a copy is owed at all. `tree` is freshly built by `_parseTokens` and
  // unshared, so handing it straight back is safe. Worth ~28% of parse.
  List<Object?>? rebuilt;
  for (var i = 0; i < tree.length; i++) {
    final element = tree[i];
    if (element == null) continue;
    final converted = _listToDict(element);
    if (!identical(converted, element)) {
      rebuilt ??= List<Object?>.of(tree);
      rebuilt[i] = converted;
    }
  }
  return rebuilt ?? tree;
}
