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
  and `patch.pl`. A separate differential runner (`tools/differential.pl`)
  and cases under `tests/differential/` are also implemented. Development
  checks are configured in `.pre-commit-config.yaml`, with YAML rules in
  `.yamllint.yaml` and Perl::Critic policy selections in `.perlcriticrc`.
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
- Differential result: `perl tools/differential.pl --reference /usr/bin/patch`
  reports **88 PASS, 0 FAIL, 0 SKIP**, exit 0 on Perl 5.42.3. The cases cover
  CLI parsing and environment variables and uncovered defects in short-option
  clusters, permutation of separate arguments, `-d`, unknown short options,
  backup-style abbreviations/diagnostics, and empty environment precedence;
  these were fixed without changing the GNU reference suite. Added coverage
  checks fractional timestamp matching and `-T`, `Prereq:`, `-D`, ed failure
  edges, PTY prompt responses, `locale`/`clocale` quoting under C and C.utf8,
  and multi-file backup/reject/dry-run/output workflows.
- `patch.pl` uses Time::HiRes fractional `stat` results and splits timestamp
  seconds/nanoseconds explicitly; core stat has no separate nanosecond fields.
  Differential fixtures exercise representative fractions, but Time::HiRes exposes
  timestamps as floating-point values, so this does not establish exact preservation
  of every filesystem nanosecond value.
- Differential PTY cases use the test-only IO::Pty module, which is not required
  by `patch.pl` at runtime.
- `tests/ownership-fallback.sh` checks GNU's group-only chown retry with a
  controlled foreign-owner fixture; it requires `setpriv` and passwordless sudo.
- Code-quality review completed in focused commits: byte-stream reads use a
  shared `read_all` helper with large-input regression cases and copies use a
  bounded-memory stream helper; hunk storage no longer simulates C allocation or
  freeing; deferred filesystem queues snapshot stat data and retain unprocessed
  entries; test runners distinguish process exit/signal/timeout/setup results;
  short-option metadata is derived from the option table.
- Runtime compatibility is required with Perl 5.22.1 and newer. Test runners use
  their system Perl. Perl 5.22.1 remains the syntax, core-module, and API
  compatibility baseline; minimum-version test execution is not a completion
  requirement.
- Porting decisions worth review: GNU's merge leaves the diffseq
  `too_expensive` heuristic uninitialized in C; the Perl port pins it to a
  large constant (effectively disabling the give-up path) and this matches
  GNU's practical behavior on test-sized inputs. GNU's fd-based safe path
  traversal is emulated with lstat-based component checks. The `--help`
  bug-report line differs on purpose (Camel patch project), as does the product
  name in `--version`; the "Written by Larry Wall and Paul Eggert" line of
  GNU's `--version` output is intentionally not printed.
- The initial environment has GNU patch 2.8, GNU diffutils 3.12, ed, and Perl
  5.42.3. Recheck tool versions when working in another environment.
- Test-suite facts verified from the pinned checkout: 49 test scripts; expected
  failures `context-format` and `dash-o-append`; the Haiku-only XFAIL for
  `preserve-mode-and-timestamp` does not apply on Linux; no GNU reference test
  exercises legacy VCS retrieval, so that exclusion affects no tests.
- Remaining verification gaps: broader coverage of uncommon CLI/environment
  interactions, prompt sequences beyond the tested prerequisite and reverse
  prompts, metadata beyond timestamp matching, quoting outside the available C
  and C.utf8 locales, and GNU behaviors not exercised by either test path. The
  differential suite remains targeted rather than exhaustive.

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
  verifying availability in the minimum supported Perl release.
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
tools/differential.pl      separate project-owned differential runner
tests/differential/        named CLI and environment differential cases
gnu-patch/                 GNU patch reference checkout pinned to the target release
build/                     ignored scratch area, created by the test runner
```

Implemented: `AGENTS.md`, `LICENSE`, `README.md`, `.gitmodules`,
`compat/2.8.json`, `tools/test.pl`, `tools/differential.pl`, `tests/differential/`,
`gnu-patch`, `patch.pl`.

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
- Use a launcher to preserve executable-path diagnostics against GNU reference
  expectations; do not broadly filter those paths from comparisons.
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
- Records child exit status and signal separately. Timeouts, signals, and
  runner setup failures are FAIL/ERROR results, never XFAIL; only a normal exit
  status of 1 can satisfy a GNU expected-failure declaration.
- Exit status is 0 only with no FAIL, no XPASS, and no SKIP; a skip means
  incomplete coverage. `--timeout` (default 300 s) kills runaway tests.
- In default mode it generates `build/patch`, a Perl launcher that `do`s
  `patch.pl` with the system Perl running `tools/test.pl` so `$0` (hence
  program-name diagnostics) matches the invoked program name, which GNU
  reference expectations such as `bad-usage` rely on.
  This path is exercised by the suite run and matches the GNU baseline.
- Establish the GNU baseline with `--patch /usr/bin/patch`; recorded baseline:
  47 PASS, 2 XFAIL, 0 SKIP, verdict PASS.

### Separate differential runner (verified)

Keep the two test paths separate: `tools/test.pl` exercises GNU's reference
scripts, while `tools/differential.pl` runs project-owned comparisons only.
Do not make either runner implicitly invoke the other.

```sh
perl tools/differential.pl --reference /usr/bin/patch
perl tools/differential.pl --group cli
perl tools/differential.pl --case cli.short-clusters
perl tools/differential.pl --list
pre-commit run --all-files
```

The pre-commit checks run separately from both compatibility test paths and
cover repository hygiene, YAML, spelling, Perl::Critic, and ShellCheck.

- Cases are array references returned by `tests/differential/*.pl`, with unique
  `group.name` identifiers. They declare arguments, input bytes, environment
  overrides, initial files, and optional symlinks/hardlinks. File specifications
  can include modes and mtimes; `compare_mtime` selects files whose mtimes matter.
- Group/case selectors accept repeats and comma-separated names. Both selectors,
  when supplied, are intersected. Unknown selections abort instead of silently
  running no tests. `--list` does not execute the targets.
- The runner checks the reference executable's version against the selected
  manifest (`--manifest`, default newest version). It uses the system Perl
  running `tools/differential.pl` and a dedicated launcher; it never writes
  `build/patch`, which belongs to the GNU-suite runner.
- Each process gets isolated files, a fixed umask, C locale, UTC timezone, and
  cleaned patch/Perl environment defaults. Environment cases explicitly override
  these defaults. Processes have no controlling terminal; actual terminal-prompt
  coverage remains a separate verification gap.
- Compares exit status, signal, separate stdout/stderr streams, file contents,
  directory structure, modes, ownership, symlink targets, and hardlink relations.
  Independent inode numbers and incidental timestamps are not equal across runs;
  relevant mtimes are explicitly selected by a case.
- The initial cases normalize only program-name differences in diagnostic prefixes
  and usage hints. Raw outputs remain available for review. Do not add broad
  normalization to hide a mismatch. Identity-output cases will need explicit
  treatment of the already-approved version/help differences when added.
- Artifacts are retained under `build/differential/run.XXXXXX/<case>/`:
  `reference/` and `camel/` each contain `work/`, `stdin`, `stdout`, `stderr`,
  `status.json`, and `tree.json`; `result.json` lists mismatched fields.
  `run.json` records the system interpreter, reference, manifest, and selected cases.
- Default timeout is 10 seconds per process (`--timeout`); a timeout or signal
  fails the case. Exit 0 means all selected cases match, 1 means differences,
  and 2 means runner/prerequisite trouble. The initial cases need no extra tools
  beyond Perl, the reference executable, and the normal Linux filesystem.
- GNU-suite XFAIL expectations are not imported: equal reference behavior is a
  differential PASS, including behavior that GNU itself considers a known bug.

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
  XPASS results, and complete supported coverage on the current system Perl.
  Perl 5.22.1 remains the implementation compatibility baseline, but running
  the suite on that interpreter is not a completion requirement. Report remaining
  gaps honestly.

## Initial implementation sequence

1. Create this guide (the current step).
2. Add and verify the pinned GNU reference checkout, LICENSE, compatibility manifest,
   brief README, and test infrastructure. Establish the GNU baseline.
3. Implement CLI behavior and exact unified patch application.
4. Implement offsets, fuzz, reversal, whitespace handling, and multiple hunks.
5. Add normal/context/Git-style parsing, filename rules, creation/deletion, and ed.
6. Add rejects, backups, dry-run/output modes, merge, `-D`, and prompts.
7. Close filesystem and malformed-input compatibility gaps.
8. Complete full-suite and differential verification in environments with the
   minimum supported system Perl and a current system Perl.

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
8. Verify on a current system Perl. Keep implementation compatible with Perl
   5.22.1; the minimum does not rise implicitly with a new GNU release, and a
   minimum-version runtime test is not required. Discuss any proposed baseline
   change with the user.
9. Update this guide with the actual repository state, target revision, working
   commands, approved decisions, and verification results. Summarize completion
   and remaining gaps to the user. Commit or release only if requested.
