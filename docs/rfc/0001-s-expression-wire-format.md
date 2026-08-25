# RFC-0001: The Aiko S-expression Wire Format

| | |
|---|---|
| **RFC** | 0001 |
| **Category** | Standards Track (protocol specification) |
| **Status** | Draft |
| **Reference implementation** | `aiko_services/main/utilities/parser.py` (Python; normative) |
| **Conformance suite** | `aiko_services_dart/test/codec/fixtures/s_expression_golden.json` (generated from the reference; 15 encode + 15 decode vectors) |
| **Created** | 2026-07-18 |

## 1. Introduction

Every message that crosses an Aiko Services actor boundary — a remote function
call, an Eventual Consistency state delta, a Registrar discovery message — is a
single S-expression string. This document specifies that format precisely
enough that an independent implementation in any language can be written from
this document alone and verified against the conformance suite.

The format is a restricted dialect of canonical S-expressions
[[Rivest97]](https://datatracker.ietf.org/doc/html/draft-rivest-sexp-00): a
parenthesized list of elements, where an element is an atom, a quoted string,
a length-prefixed symbol, a null, a nested list, or a keyword dictionary.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be
interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

### 1.1. Relationship to the reference implementation

Where this document and `parser.py` disagree, `parser.py` is normative and
this document has a defect; §8 records the known points where the reference
implementation's behaviour is accidental rather than intended. Conformance is
defined as byte-for-byte agreement with the conformance suite, which is
mechanically generated from the reference implementation
(`aiko_services_dart/tool/generate_codec_fixtures.py`).

## 2. Data model

A payload encodes a tree whose nodes are:

| Node | Description |
|------|-------------|
| symbol | a Unicode string |
| null | the distinguished absent value |
| list | an ordered sequence of nodes |
| dictionary | an ordered map from string keywords to nodes |

There are no other types. Numbers, booleans, and any richer types MUST be
rendered as symbols by the sender and re-interpreted by the receiver
(§6.3). A complete payload is always a list; a bare symbol outside
parentheses is not a valid payload.

### 2.1. Command form

The framework's calling convention layers one rule on the data model: a
payload's first element is the *command* (a symbol), and the remaining
elements are its *parameters* — either all positional (a list) or all
keyword (a dictionary). Mixing positional and keyword parameters in one
payload is invalid (§5.4).

```
(increment 5)                 command "increment", positional ["5"]
(update log_level DEBUG)      command "update",    positional ["log_level", "DEBUG"]
(a b: 1 c: 2)                 command "a",         keyword {"b": "1", "c": "2"}
```

## 3. Lexical elements

A payload is a sequence of Unicode characters. Implementations exchanging
payloads as bytes MUST encode them as UTF-8.

### 3.1. Delimiters

`(` opens a list; `)` closes it. Space (U+0020), tab (U+0009), and newline
(U+000A) separate elements. Consecutive separators are equivalent to one.

### 3.2. Plain atoms

Any maximal run of characters containing no delimiter (§3.1) is an atom.
Atoms are the common case: `increment`, `5`, `log_level`, `😀🎉`.

### 3.3. Length-prefixed symbols

A symbol whose content could be misread as structure is written
`<length>:<content>`, where `<length>` is a run of ASCII digits.

- `<length>` MUST equal the number of Unicode **code points** in
  `<content>`. It is not a count of UTF-16 code units, not a count of UTF-8
  bytes, and not a count of grapheme clusters (a ZWJ emoji family is one
  glyph and seven code points). `a 😀` is three code points: `3:a 😀`.
- In implementations whose strings can contain unpaired surrogates
  (UTF-16-based languages), a lone surrogate is **one** code point. A
  decoder MUST treat two units as one code point only when a high surrogate
  (U+D800–U+DBFF) is immediately followed by a low surrogate
  (U+DC00–U+DFFF); pairing a high surrogate with an arbitrary next unit
  over-consumes and can swallow structural delimiters.
- A decoder encountering `<digits>:` at the start of an element MUST consume
  exactly `<length>` code points following the `:` as the symbol's content,
  including any delimiter characters within them.
- `0:` does not introduce a symbol; it encodes null (§3.5).
- A length prefix is recognized only when **at least one character follows
  the colon**. The reference pattern is `^(\d+):(.+)`, and that `.+` is
  load-bearing: a trailing `0:` or `12:` at end of input is not a prefix at
  all, but the ordinary atom `0:` / `12:`. Inside a payload the closing `)`
  supplies the required character, which is why `(c 0:)` still decodes to
  null while a bare `0:` decodes to the two-character atom. An implementation
  that omits this reads a bare `0:` as null, and a bare `12:` as an overlong
  prefix to be rejected — both diverging from the reference on input the
  reference accepts.

The prefix is only recognized at the *start* of an element; a `:` later in an
atom (for example the dictionary keyword `b:`) has no length-prefix meaning.

### 3.4. Quoted strings

A decoder MUST accept `"content"` and `'content'` at the start of an element
as a symbol whose value is `content` (without the quotes). There is no escape
mechanism: `content` extends to the next occurrence of the opening quote
character and therefore cannot contain it. An encoder MUST NOT emit quoted
strings (§4 produces length-prefixed symbols instead); the quoted form is an
input convenience only, and a decode→encode round trip does not preserve it.

### 3.5. Null

The two-character sequence `0:` encodes null. A decoder MUST yield its
language's distinguished absent value (`None`, `null`, `nil`), not an empty
string.

### 3.6. Empty string

The empty symbol is encoded as `""` (two QUOTATION MARK characters). See
§8.3 for a decoding asymmetry.

## 4. Encoding

Encoding takes a command and its parameters and produces the payload string.
An encoder MUST apply the following rules to each element, in order:

1. If the element is a string that begins with `<digits>:` or contains any
   character of the **prefix-trigger set** (§4.1), replace it with
   `<code-point-count>:<content>` (§3.3).
2. If the element is a dictionary, flatten it in insertion order to the
   sequence `k₁: v₁ k₂: v₂ …` — each keyword becomes an atom `<keyword>:`,
   each value is encoded by these same rules (§5).
3. If the element is a list, encode it recursively as `(…)`.
4. If the element is the empty string, emit `""`.
5. If the element is null, emit `0:`.
6. Any other value (number, boolean, object) is rendered with the host
   language's default string conversion. Senders SHOULD restrict themselves
   to values whose rendering is portable (ASCII decimal for integers).

Elements are joined with a single space and wrapped in `(` `)`.

An encoder MUST NOT emit quoted strings, and MUST NOT length-prefix a symbol
that rule 1 does not require it to (the conformance suite enforces canonical
output: `(add topic protocol owner)`, never `(add 5:topic …)`).

### 4.1. The prefix-trigger set

The reference implementation spells rule 1 as the pattern `^\d+:|[\s()]`.
That pattern is **not portable**: `\s` denotes a different set of characters
in different languages, so two conformant-looking encoders can emit different
bytes for the same input. This specification therefore enumerates the set,
and implementations MUST NOT substitute their host language's `\s`.

An element is length-prefixed if it contains any of:

| Code point(s) | |
|---|---|
| U+0009–U+000D | tab, LF, VT, FF, CR |
| U+001C–U+001F | file, group, record, unit separators |
| U+0020 | space |
| U+0028, U+0029 | `(` and `)` |
| U+0085 | next line (NEL) |
| U+00A0 | no-break space |
| U+1680 | ogham space mark |
| U+2000–U+200A | en quad … hair space |
| U+2028, U+2029 | line, paragraph separator |
| U+202F, U+205F | narrow no-break, medium mathematical space |
| U+3000 | ideographic space |

U+FEFF (zero-width no-break space / BOM) is **NOT** in the set, though some
languages include it in `\s`. Note this set is deliberately **wider** than the
delimiter set of §3.1: a decoder separates elements on only space, tab and
newline, so most of these characters never actually needed prefixing. The
excess is harmless — it costs bytes, not correctness — but it is normative,
because canonical output must be reproducible byte-for-byte by any
implementation.

Divergence here does not corrupt a round-trip: an encoder that under- or
over-prefixes one of these still produces a payload every conformant decoder
reads back identically. It breaks anything that hashes, signs, deduplicates or
compares payload bytes. Conformance vectors covering both directions are in
`test/codec/fixtures/s_expression_golden.json` (the `ws` cases).

## 5. Dictionaries

### 5.1. Detection

After structural decoding, a list whose first element is a non-empty string
ending in `:` MUST be re-interpreted as a dictionary.

### 5.2. Well-formedness

Such a list MUST have even length, and every even-indexed element MUST be a
string ending in `:`. The keyword is the string with its trailing `:`
removed. Values are recursively re-interpreted (a value list may itself be a
dictionary). A violation MUST be rejected with an error (§7).

### 5.3. Nesting

`(a b: 1 c: (d: 1 e: 2))` decodes to command `a` with keyword parameters
`{"b": "1", "c": {"d": "1", "e": "2"}}`.

### 5.4. No mixing

`(a b: 1 c)` (keyword then positional) and `(a: 1 (b c) 2)` are invalid.
Decoders MUST reject them via §5.2.

### 5.5. Keyword collision

The character sequence `<word>:` is structurally ambiguous: as a dictionary
keyword it is `<word>`, as data it is a symbol ending in `:`. Encoding
resolves the ambiguity: symbol *data* ending in `:`… is length-prefixed only
if it matches rule §4.1, which `b:` does not. Senders MUST NOT use symbols
ending in `:` as the first positional parameter of a list; the decoded result
will be misinterpreted as a dictionary. (Inherited from the reference
implementation; see §8.4.)

## 6. Decoding

### 6.1. Structure

The decoder tokenizes per §3, building nested lists for `(` `)`. The result
of decoding a complete payload is the command (first element of the outer
list, or `""` if absent) and the parameter list (the remaining elements),
after dictionary re-interpretation (§5).

### 6.2. Termination

The outer list SHOULD be properly closed. See §8.1 for reference behaviour
on unterminated input.

### 6.3. Type fidelity

All leaf values decode as strings (or null). `(increment 5)` yields the
string `"5"`; the receiver applies its own numeric conversion. Encoding does
not round-trip host types — `5` (integer) encodes to what `"5"` (string)
encodes to — and implementations MUST NOT rely on type information surviving
the wire.

## 7. Errors

A conforming decoder MUST reject, with a decode error distinguishable from
success:

| Condition | Reference behaviour |
|-----------|--------------------|
| Odd-length dictionary: `(c a: 1 b:)` | `ValueError` |
| Even-indexed dictionary element not a string ending in `:` | `ValueError` |
| Length prefix exceeding remaining input: `(c 99:ab)` | crash (§8.2) |

Encoders have one defined error: parameters that are neither a list nor a
dictionary MUST be rejected.

## 8. Known defects and divergences (errata)

Behaviours of the reference implementation that this specification records
but does not endorse. Probed directly against `parser.py` on 2026-07-18.

### 8.1. Unterminated input

The reference implementation raises an unhandled `TypeError` (an internal
return-shape confusion, not a deliberate error) on unterminated input such as
`(c a b`. The Dart implementation currently decodes it leniently as if
closed. Neither behaviour is specified; implementations SHOULD reject
unterminated input with a clean decode error, and the reference SHOULD be
fixed to do likewise.

### 8.2. Overlong length prefix

The reference implementation crashes with an unhandled `TypeError` (the
`.+` in `RE_CANONICAL_SYMBOL` consumes past the intended symbol, corrupting
list structure). The Dart implementation raises a clean `FormatException`.
Implementations SHOULD follow the Dart behaviour; the requirement in §7 is
only that the input not decode successfully.

### 8.3. Empty-string asymmetry

`""` encodes the empty symbol (§3.6), but decodes via the quoted-string rule
(§3.4) — which is only recognized at the start of an element. The sequence
`( "")` (as the encoder emits, with a leading space) round-trips; other
placements of an empty string may not. Additionally, when the empty string is
the *first* element of a list the reference encoder emits a leading space:
`generate('c', [''])` → `(c "")` but `generate('', [])` → `( "")`.

### 8.4. Keyword-shaped data

§5.5's collision is resolved by convention, not by the grammar. A future
revision could length-prefix all data symbols ending in `:`, making the
grammar unambiguous; this would change canonical output and therefore needs
a coordinated version bump.

### 8.5. Trailing data after the first list

The reference reads only the first parsed element (`tree[0]`) as the payload's
car/cdr, so anything after the first complete list is silently discarded:
`(c) garbage` and `(c)(evil a: 1)` both decode as `('c', [])`. The Dart
implementation mirrors this exactly — a stricter Dart envelope check would
reject payloads the reference *accepts*, making the two ends of the wire
disagree, which is a worse failure than lenient parity. A future revision that
wants strict single-list envelopes must change `parser.py` (§10) so both ends
move together. Recorded, not endorsed; pinned as a parity vector in the
conformance suite.

### 8.6. Non-symbol command position

The reference is dynamically typed, so the `car` it returns is whatever sat in
command position: normally a symbol, but `None` for a `0:` there (`( 0:)` →
`(None, [])`) and a list for a nested list there (`((a b) c)` → `(['a','b'],
['c'])`).

No conformant encoder can produce either shape. §4 builds a payload from a
command and its parameters, and every reference sender supplies a symbol —
`generate(method_name, ...)` in `transport/transport_mqtt.py` and
`discovery.py` — so these arise only from malformed or hostile input.

A decoder MUST NOT decode a payload whose command position is not a symbol; it
SHOULD reject it the same way as §7. This is a deliberate narrowing of the
accept-set relative to the reference, made because a command names a method to
dispatch and neither shape can name one. A statically typed implementation that
instead widens its return type to admit them propagates the ambiguity to every
caller; the Dart implementation raises `FormatException` and pins the reference
values as conformance vectors (the `divergences` fixture group).

Found by differential-fuzzing the decoder against the reference: the nested-list
form crashed the Dart cast with an exception outside the declared contract, and
the null form was silently flattened to the empty command.

## 9. Security considerations

- **No escape mechanism** (§3.4) and **content-blind length prefixes**
  (§3.3) mean any Unicode content can be carried verbatim; injection into
  surrounding structure is prevented only by correct length prefixing.
  Encoders MUST use the §4 rules and never assemble payloads by string
  interpolation of untrusted data.
- A length prefix is attacker-controlled input; decoders MUST bound it by
  the remaining input length before allocating (§8.2's clean-rejection
  behaviour).
- Deeply nested lists recurse in both reference and Dart decoders; a
  hostile payload can exhaust the stack. Decoders processing untrusted
  input SHOULD impose a nesting-depth limit.
- The format carries no authentication, integrity, or freshness. Transport
  security (MQTT authentication, TLS, WebRTC DTLS) is out of scope for this
  document and MUST be provided by the layer below.

## 10. Conformance

An implementation is conformant when, for every vector in the conformance
suite: (a) encoding the vector's `(command, params)` produces the vector's
payload byte-for-byte (UTF-8), and (b) decoding the vector's payload
produces the vector's `(command, cdr)` tree. The suite is regenerated from
the reference implementation and MUST NOT be hand-edited; proposed changes
to the format are proposed changes to `parser.py`.

## 11. References

- Reference implementation: [`aiko_services/main/utilities/parser.py`](https://github.com/geekscape/aiko_services/blob/main/src/aiko_services/main/utilities/parser.py)
- Conformance suite + generator: [`aiko_services_dart`](https://github.com/nickmeinhold/aiko_services_dart) `test/codec/fixtures/s_expression_golden.json`, `tool/generate_codec_fixtures.py`
- Dart implementation: `aiko_services_dart/lib/src/codec/s_expression.dart`
- R. Rivest, [*S-Expressions* (draft-rivest-sexp-00)](https://datatracker.ietf.org/doc/html/draft-rivest-sexp-00), 1997 — the canonical (length-prefixed) encoding this dialect restricts
- [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) — key-word interpretation
- Why only these strings cross actor boundaries: `aiko_services_dart/docs/distributed-seam.html`
