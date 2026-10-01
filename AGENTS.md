# Working on Camel patch

This file is the maintained guide for contributors and coding agents. Read it
before making changes. Update it as the implementation, repository layout,
verified commands, or compatibility decisions evolve. Distinguish plans from
implemented features and verified results; do not record intentions as facts.

## Current state

- The compatibility target is **GNU patch v2.8**.
- Implemented so far: `AGENTS.md`, `LICENSE` (verbatim GNU `COPYING`),
  `README.md`, compatibility manifest `compat/2.8.json`, GNU reference checkout
  `gnu-patch` (Git submodule) pinned to tag `v2.8` = commit
  `48ceda8200aaf30c3ce42c31cd70ff6087db2425`, test runner `tools/test.pl`,
  and `patch.pl`.
- `patch.pl` implements: full GNU-style CLI (getopt_long port with
  permutation, abbreviations, attached arguments, POSIX mode, environment
  defaults), patch format detection, unified/normal/context/Git-style text
  patch parsing, filename rules (best-name selection, `/dev/null`, quoted
  names, dangerous-name rejection, safe-path symlink traversal), hunk
  application with offsets/fuzz/reversal/whitespace/`-D` output, reject files
  (unified and context), backups (simple/numbered/existing, `-B/-Y/-z`),
  dry-run, `-o`/`-r`/`-E`, read-only handling, the CR-stripping heuristic,
  quoting styles, timestamps and file modes (including Git headers), symlink
  and hardlink handling, Git queued-output detection, **ed scripts**
  (restricted-subset interpreter in Perl), and **merge** (port of
  locate_merge/bestmatch/diffseq with conflict markers).
- Suite result: `perl tools/test.pl` reports **47 PASS, 2 XFAIL**
  (`context-format`, `dash-o-append`), 0 FAIL, 0 SKIP, verdict PASS, exit 0 --
  matching the recorded GNU baseline. The launcher (`build/patch`) is
  exercised by this and preserves `$0` for program-name diagnostics.
- Not yet verified: Perl 5.22.1 (not provisioned); the suite has been run on
  Perl 5.42.3 only.
- Porting decisions worth review: GNU's merge leaves the diffseq
  `too_expensive` heuristic uninitialized in C; the Perl port pins it to a
  large constant (effectively disabling the give-up path) and this matches
  GNU's practical behavior on test-sized inputs. The `locale`/`clocale`
  quoting styles are approximated with Unicode quotes. GNU's fd-based safe
  path traversal is emulated with lstat-based component checks. The `--help`
  bug-report line differs on purpose (Camel patch project), as does the product
  name in `--version`; the "Written by Larry Wall and Paul Eggert" line of
  GNU's `--version` output is intentionally not printed.
- The initial environment has GNU patch 2.8, GNU diffutils 3.12, ed, and Perl
  5.42.3. Recheck tool versions when working in another environment. Perl
  5.22.1 has not yet been provisioned.
- Test-suite facts verified from the pinned checkout: 49 test scripts; expected
  failures `context-format` and `dash-o-append`; the Haiku-only XFAIL for
  `preserve-mode-and-timestamp` does not apply on Linux; no GNU reference test
  exercises legacy VCS retrieval, so that exclusion affects no tests.
- Remaining verification gaps for final acceptance: differential tests for
  behavior outside the suite (option parsing corners, prompts, `Prereq:`,
  environment variables), Perl 5.22.1 run, and a scan of GNU behaviors not
  exercised by the suite.

Update this section when these facts change.

## Mission and compatibility contract

Implement a readable, idiomatic Perl replacement for GNU patch. The executable
is named `patch.pl`, and its product name is **Camel patch**.

The target is full observable compatibility with the selected GNU patch release,
subject to the explicit exclusions below. This includes command-line parsing,
environment variables, patch parsing and application, prompts, diagnostics,
stdout/stderr routing, exit statuses, backups, rejects, and filesystem effects.
Passing the GNU reference suite is necessary but does not establish full compatibility.
Use the selected release's source, documented behavior, and reference executable
to investigate behavior beyond the suite.

- Replace product branding such as `GNU patch` with `Camel patch`, including
  `--version`. The initial compatibility version is 2.8.
- Preserve exit statuses: 0 for success, 1 for unapplied hunks or merge conflicts,
  and 2 for serious trouble, following GNU's behavior in each case.
- Match GNU's treatment of unsupported input. For example, GNU patch v2.8 rejects
  Git binary patches; implementing them would change the target behavior.
- Do not recreate GNU's manual. Provide concise project documentation and usage
  information, while implementing observable CLI behavior such as `--help`.
- Target Linux first. Keep the code portable where practical; other operating
  systems are not part of the initial acceptance scope.

### Approved scope decisions

- Support unified, normal, context, and Git-style text patches.
- Retain merge modes, `Prereq:` checking, and `-D NAME` conditional output.
- **Retain ed-format patches**, implemented directly in Perl. This supersedes an
  earlier proposal to exclude them. GNU patch accepts a restricted ed command
  subset; inspect the pinned source instead of implementing a complete editor.
- **Exclude legacy VCS checkout integrations**, such as RCS, SCCS, ClearCase, and
  Perforce retrieval. The tool is intended to operate offline. Record the exact
  handling of related options when implemented; do not silently claim support.
- Ask the user before excluding additional legacy features or narrowing the
  compatibility contract. Document approved changes and affected tests.

## Runtime, dependencies, and licensing

- All runtime implementation must reside in **one self-contained `patch.pl`**.
  Do not split it into project-owned runtime modules or auxiliary executables.
- Support **Perl 5.22.1 and newer**. Do not use newer syntax or module APIs without
  verifying availability in 5.22.1.
- Use only Perl modules shipped with Perl by default. No CPAN installation may be
  required to run the script. Check each chosen module against the minimum Perl.
- External runtime tools, if needed, must be provided by Debian Essential
  packages. Do not delegate patch application to another `patch` executable.
- Runtime operation must not require network access.
- Development and test dependencies are separate. Shell utilities, GNU diff,
  GNU patch of the selected version, and **ed** may be test-only dependencies.
  The external `ed` executable must not be required by `patch.pl`.
- Add `LICENSE` by copying the target GNU release's `COPYING` verbatim. GNU patch
  v2.8 uses **GPL-3.0-or-later** licensing terms; use the same terms for this project.
- Camel patch's copyright owner is **Canonical Ltd**; the author is
  Paride Legovini <paride@ubuntu.com>. `patch.pl` carries this attribution in
  standard SPDX header tags (SPDX-FileCopyrightText, SPDX-FileContributor,
  SPDX-License-Identifier).
- Preserve applicable copyright and license notices for material adapted from
  the GNU reference. Keep product branding distinct from legal attribution.

## Repository layout

```text
AGENTS.md                  maintained contributor and agent guide
patch.pl                   complete runtime implementation
LICENSE                    verbatim GNU GPL license text
README.md                  purpose, usage, dependencies, testing, exclusions
.gitmodules                GNU reference repository location
compat/2.8.json            target revision, expectations, approved exclusions
tools/test.pl              project-owned test runner
tests/                     additional regression and differential tests (planned)
gnu-patch/                 GNU patch reference checkout pinned to the target release
build/                     ignored scratch area, created by the test runner
```

Implemented: `AGENTS.md`, `LICENSE`, `README.md`, `.gitmodules`,
`compat/2.8.json`, `tools/test.pl`, `gnu-patch`, `patch.pl`. Planned: `tests/`.

The runner ignores `build/`: it writes per-test logs to `build/logs/<target>/`
and runs tests in scratch directories under `build/work.<pid>` (removed after
the run unless `--keep`). Generated launcher: `build/patch`.

Use **https://git.savannah.gnu.org/git/patch.git** for the GNU reference
checkout. Pin it to the exact commit identified by `v2.8`, not a moving branch. Record both
the tag and resolved commit in the compatibility manifest. Keep GNU reference files
unmodified; project-owned adapters belong outside the checkout.

Compatibility manifests should record target provenance, GNU reference expected
failures, and approved exclusions with reasons and affected test cases. Retain
older manifests for provenance. Historical project releases preserve older
implementations; simultaneous runtime compatibility modes are not required.

## Implementation practices

- Use `strict`, `warnings`, lexical filehandles, small named functions, and
  explicit state. Favor clear code over clever expressions or line-count goals.
- Organize the substantial single file into clear sections: CLI, parsing,
  filename selection, hunk matching/application, output, and filesystem work.
- Preserve input bytes, including NULs, CRLFs, and missing final newlines. Avoid
  implicit Unicode decoding or accidental newline normalization.
- Match GNU option parsing deliberately, including ordering, abbreviations,
  attached arguments, environment defaults, and POSIX behavior. A core option
  parser's defaults are not automatically equivalent to GNU getopt behavior.
- Keep parsing, application decisions, diagnostics, and filesystem effects
  sufficiently separated to review and compare against GNU behavior.
- Investigate unfamiliar changes as possible user work before editing them.
- Do not commit, amend, push, or create releases unless explicitly requested.

## Testing workflow

### GNU reference harness integration

GNU v2.8's tests source `tests/test-lib.sh`. Its `use_local_patch` function accepts
a `PATCH` override. This lets the runner execute the GNU reference shell tests against
`patch.pl` without compiling GNU patch or bootstrapping gnulib.

- Supply the required `srcdir` and `abs_top_builddir` values and isolated scratch
  directories. Keep logs outside directories removed by GNU reference cleanup traps.
- Use a launcher when selecting a Perl interpreter. Verify executable-path
  diagnostics against GNU reference expectations rather than broadly filtering them.
- Install `ed` in the complete test environment: `ed-style` requires it, and
  `crlf-handling` and `need-filename` contain ed sections gated by `have_ed`.
  Do not disable those sections merely because our runtime implements ed itself.
- Derive the test inventory and expected failures from the pinned release, with
  any platform-specific expectations handled explicitly.
- Verify the checked-out GNU reference commit matches the requested manifest. Fail
  clearly on a mismatch; do not silently test against a different release.

### Runner interface (verified)

```sh
git submodule update --init
perl tools/test.pl                          # test patch.pl via build/patch launcher
perl tools/test.pl --patch /usr/bin/patch   # GNU reference baseline
perl tools/test.pl --test asymmetric-hunks  # selection accepts repeats and commas
perl tools/test.pl --list                   # inventory with expected failures
perl tools/test.pl --perl /path/to/perl-5.22.1
```

Verified behavior of `tools/test.pl`:

- Reads the newest `compat/<version>.json` (or `--manifest`), verifies the
  submodule checkout matches the manifest commit, and cross-checks expected
  failures against the GNU reference `tests/Makefile.am`; mismatches abort the run.
- Derives the inventory from the GNU reference `Makefile.am`; runs each script with
  `/bin/sh`, `srcdir` pointing at the pinned tests directory, a fresh scratch
  `abs_top_builddir`, and `PATCH` set to the target under test.
- Labels results PASS, FAIL, SKIP, XFAIL, XPASS; exit 77 from a script means
  SKIP with the missing prerequisite reported. Per-test logs are kept under
  `build/logs/<target>/<test>.log`.
- Exit status is 0 only with no FAIL, no XPASS, and no SKIP; a skip means
  incomplete coverage. `--timeout` (default 300 s) kills runaway tests.
- In default mode it generates `build/patch`, a Perl launcher that `do`s
  `patch.pl` so `$0` (hence program-name diagnostics) matches the invoked
  program name, which GNU reference expectations such as `bad-usage` rely on.
  This path is exercised by the suite run and matches the GNU baseline.
- Establish the GNU baseline with `--patch /usr/bin/patch`; recorded baseline:
  47 PASS, 2 XFAIL, 0 SKIP, verdict PASS.

### Result policy and iteration

- Report PASS, FAIL, SKIP, XFAIL, and XPASS explicitly, retaining useful logs.
- Distinguish approved feature exclusions from missing prerequisites. A missing
  dependency is never a pass; report incomplete coverage.
- Record every feature skip with a reason. Preserve supported coverage within
  mixed-feature tests instead of indiscriminately skipping whole scripts.
- Apply GNU reference expected-failure declarations only where justified for the
  target platform. Compare with the GNU baseline; investigate unexpected passes
  and unexpected failures rather than hiding them.
- Never add an exclusion, weaken an assertion, or broadly normalize output just
  to obtain a passing result. New exclusions require the user's agreement.
- Establish the baseline using a GNU executable of the **exact target version**.
  If it is unavailable, build or obtain it as a development dependency.
- Implement a coherent feature group, run relevant tests, investigate differences,
  fix the implementation, and rerun affected tests. Run the full suite at milestone
  boundaries and at completion to catch interactions and regressions.
- Add meaningful differential tests for gaps in the GNU reference suite, particularly
  option parsing, environment behavior, prompts, `Prereq:`, `-D`, and ed edge cases.
  Compare statuses, stdout/stderr, contents, backups, rejects, links, directory
  structure, and relevant metadata in equivalent isolated environments.
- Differential comparisons may normalize declared branding and executable-path
  differences only; other normalization needs a specific justification.
- Final acceptance requires no unexplained or unexpected failures, no unreviewed
  XPASS results, and complete supported coverage on Perl 5.22.1 and a current Perl.
  Report unavailable verification or remaining gaps honestly.

## Initial implementation sequence

1. Create this guide (the current step).
2. Add and verify the pinned GNU reference checkout, LICENSE, compatibility manifest,
   brief README, and test infrastructure. Establish the GNU baseline.
3. Implement CLI behavior and exact unified patch application.
4. Implement offsets, fuzz, reversal, whitespace handling, and multiple hunks.
5. Add normal/context/Git-style parsing, filename rules, creation/deletion, and ed.
6. Add rejects, backups, dry-run/output modes, merge, `-D`, and prompts.
7. Close filesystem and malformed-input compatibility gaps.
8. Complete full-suite and differential verification on the minimum/current Perl.

Adjust milestone ordering when dependencies justify it, while keeping verification
and this guide current. Ask the user about genuine scope or compatibility decisions;
routine implementation choices should not require another planning phase.

## When GNU releases a new version

Treat a request to support a new GNU patch release as an implementation task, not
merely a submodule update:

1. Read this guide and inspect the working tree. Identify the currently implemented
   target, existing exclusions, and outstanding verification gaps.
2. Fetch the GNU release tag, resolve its exact commit, and inspect NEWS,
   source changes, test changes, and licensing changes against the previous target.
3. Update the GNU reference checkout pin and add the new version's compatibility
   manifest. Review inherited exclusions and changed expected failures explicitly.
4. Establish the new GNU reference baseline in the target Linux environment.
5. Implement new features and changed observable behavior. Ask before skipping new
   legacy features or changing established scope. Do not carry exclusions forward
   without checking their applicability.
6. Update Camel patch's compatibility version, help where affected, README, and adapted
   code notices. Verify LICENSE still matches the reference COPYING.
7. Iterate through affected tests and then the full suite. Add differential cases
   for new or changed behavior that the GNU reference tests do not cover.
8. Verify with Perl 5.22.1 and a current Perl. The minimum does not rise implicitly
   with a new GNU release; discuss any proposed change with the user.
9. Update this guide with the actual repository state, target revision, working
   commands, approved decisions, and verification results. Summarize completion
   and remaining gaps to the user. Commit or release only if requested.
