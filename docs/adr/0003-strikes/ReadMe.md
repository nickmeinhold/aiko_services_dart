# Raw strikes — ADR-0003 design-temper, run `dt-1788521696` (2026-09-04)

The four adversaries' unedited output. [`../0003-TEMPER.md`](../0003-TEMPER.md) is the synthesis
and the verdict; these are what it was synthesised from, kept because the synthesis necessarily
compresses and two of the sharpest findings read better whole.

| File | Family | Verdict |
|---|---|---|
| `maxwell.md` | Claude (author instance) | RECAST |
| `kelvin.md` | Gemini 2.5 Pro | DISSOLVE |
| `carnot.md` | GPT (Codex) | DISSOLVE |
| `tesla.md` | Grok | RECAST |

Worth reading in the original: Kelvin's opening flaw ("the design is a solution for a function
that cannot be called"), and Tesla's `s_02` §4 catch, which is the only finding that is
simultaneously a conformance error and a security hole.

`tesla.md` begins with two stalled preambles before the strike proper. They are left in
deliberately: they are why Tesla was written up as a dark seat while it was still working, and
the correction is recorded in TEMPER.md.

The adversaries were given the ADR **plus the primary sources it cites** — `s_02` in full, P1,
`actor.py:160-195` — so they could check its readings rather than inherit them. Two of the seven
fatal flaws are misreadings the ADR made after already self-correcting three times, and neither
would have been found by a panel handed only the summary.
