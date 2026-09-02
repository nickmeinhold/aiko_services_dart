# Contributing

Thanks for looking. This is a Dart port of
[geekscape/aiko_services](https://github.com/geekscape/aiko_services); the Python repo is the
reference implementation, and where the two disagree the disagreement is a finding worth writing
down rather than a bug to quietly paper over.

## Licence

This project is licensed under the [Apache License 2.0](LICENSE).

Section 5 of that licence already covers contributions: anything you deliberately submit for
inclusion is licensed to the project under the same terms, unless you say otherwise in writing.
**There is no separate CLA to sign.** Please do not add per-file copyright headers — upstream
carries none, and the `LICENSE` plus [`NOTICE`](NOTICE) cover the whole work.

## Before you open a pull request

Run everything that can falsify the package:

```sh
tool/verify.sh              # analyze, format, tests, plus the differential-fuzz rigs
tool/verify.sh --quick      # analyze, format, tests only (~2s)
```

The fuzz rigs compare this implementation against the Python reference and need it on disk:

```sh
AIKO_SERVICES=/path/to/aiko_services tool/verify.sh
```

They are the checks most likely to surprise you. A `\s` divergence of 3604 mismatches once ran
straight past 63 green golden vectors, so a green test suite is not on its own evidence of parity.

## House rules

- **Conventional Commits** for commit messages.
- **No `dynamic`** without raising it first. Reaching for it is a signal to restructure the types.
  `analysis_options.yaml` enforces strict casts, inference, and raw types.
- **Acceptance test first**, then the implementation.
- Design decisions live in [`docs/adr`](docs/adr) and [`docs/rfc`](docs/rfc). A change that alters
  wire format, actor lifecycle, or a conformance claim against the Python reference wants a
  document, not just a diff.
- Claims in prose get scoped to what was actually tested. "Parity with the reference at commit X"
  is a different statement from "correct", and only one of them is usually provable.

## Upstream conformance

Andy Gelme's [constitution](https://github.com/geekscape/aiko_services/tree/main/documentation)
is normative for behaviour this port shares with Python. If you find a place where the port and
the specification disagree, please open an issue describing both sides before changing either —
several of this repo's more useful findings started as exactly that.
