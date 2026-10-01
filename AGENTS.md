# Working on NonGNU patch

This file is the maintained guide for contributors and coding agents. Read it
before making changes. Update it as the implementation, repository layout,
verified commands, or compatibility decisions evolve. Distinguish plans from
implemented features and verified results; do not record intentions as facts.

## Current state

- The initial compatibility target is **GNU patch v2.8**.
- This repository currently contains this guide only. There is no implementation,
  upstream checkout, compatibility manifest, test runner, README, or LICENSE yet.
- No compatibility tests have been run against a project implementation.
- Planning research inspected GNU patch v2.8 source and tests. Its suite lists
  **49 test scripts**, with `context-format` and `dash-o-append` as expected
  failures. Some expectations depend on the platform.
- The initial environment has GNU patch 2.8 and Perl 5.42.3. Recheck tool versions
  when working in another environment. Perl 5.22.1 has not yet been provisioned.
- The exact upstream tag commit has not yet been recorded. Resolve and verify it
  when adding the submodule.

Update this section when these facts change.

## Mission and compatibility contract

Implement a readable, idiomatic Perl replacement for GNU patch. The executable
is named `patch.pl`, and its product name is **NonGNU patch**.

The target is full observable compatibility with the selected GNU patch release,
subject to the explicit exclusions below. This includes command-line parsing,
environment variables, patch parsing and application, prompts, diagnostics,
stdout/stderr routing, exit statuses, backups, rejects, and filesystem effects.
Passing the upstream suite is necessary but does not establish full compatibility.
Use the selected release's source, documented behavior, and reference executable
to investigate behavior beyond the suite.

- Replace product branding such as `GNU patch` with `NonGNU patch`, including
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
- Preserve applicable copyright and license notices for adapted upstream code or
  test material. Keep product branding distinct from legal attribution.

## Repository layout

The following layout is planned, not yet implemented:

```text
AGENTS.md                  maintained contributor and agent guide
patch.pl                   complete runtime implementation
LICENSE                    verbatim upstream GPL license text
README.md                  purpose, usage, dependencies, testing, exclusions
.gitmodules                upstream repository location
compat/2.8.json            target revision, expectations, approved exclusions
tools/test.pl              project-owned upstream test runner
tests/                     additional regression and differential tests
upstream/gnu-patch/        upstream Git submodule pinned to the target release
```

Use **https://git.savannah.gnu.org/git/patch.git** for the upstream submodule.
Pin it to the exact commit identified by `v2.8`, not a moving branch. Record both
the tag and resolved commit in the compatibility manifest. Keep upstream files
unmodified; project-owned adapters belong outside the submodule.

Generated launchers, adapters, logs, and scratch files should live in an ignored
build/test directory. Record its actual location here when the runner exists.

Compatibility manifests should record target provenance, upstream expected
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

### Upstream harness integration

GNU v2.8's tests source `tests/test-lib.sh`. Its `use_local_patch` function accepts
a `PATCH` override. This lets the runner execute upstream shell tests against
`patch.pl` without compiling GNU patch or bootstrapping gnulib.

- Supply the required `srcdir` and `abs_top_builddir` values and isolated scratch
  directories. Keep logs outside directories removed by upstream cleanup traps.
- Use a launcher when selecting a Perl interpreter. Verify executable-path
  diagnostics against upstream expectations rather than broadly filtering them.
- Install `ed` in the complete test environment: `ed-style` requires it, and
  `crlf-handling` and `need-filename` contain ed sections gated by `have_ed`.
  Do not disable those sections merely because our runtime implements ed itself.
- Derive the test inventory and expected failures from the pinned release, with
  any platform-specific expectations handled explicitly.
- Verify the checked-out upstream commit matches the requested manifest. Fail
  clearly on a mismatch; do not silently test against a different release.

### Runner interface

These are **proposed commands, not yet implemented or verified**:

```sh
perl tools/test.pl
perl tools/test.pl --test asymmetric-hunks
perl tools/test.pl --perl /path/to/perl-5.22.1
perl tools/test.pl --patch /path/to/gnu-patch-2.8
```

Replace this section with the actual verified interface and setup commands when
the tooling is available. Keep testing usable locally and suitable for future
GitHub Actions; adding CI is a future task, not part of the initial setup request.

### Result policy and iteration

- Report PASS, FAIL, SKIP, XFAIL, and XPASS explicitly, retaining useful logs.
- Distinguish approved feature exclusions from missing prerequisites. A missing
  dependency is never a pass; report incomplete coverage.
- Record every feature skip with a reason. Preserve supported coverage within
  mixed-feature tests instead of indiscriminately skipping whole scripts.
- Apply upstream expected-failure declarations only where justified for the
  target platform. Compare with the GNU baseline; investigate unexpected passes
  and unexpected failures rather than hiding them.
- Never add an exclusion, weaken an assertion, or broadly normalize output just
  to obtain a passing result. New exclusions require the user's agreement.
- Establish the baseline using a GNU executable of the **exact target version**.
  If it is unavailable, build or obtain it as a development dependency.
- Implement a coherent feature group, run relevant tests, investigate differences,
  fix the implementation, and rerun affected tests. Run the full suite at milestone
  boundaries and at completion to catch interactions and regressions.
- Add meaningful differential tests for gaps in the upstream suite, particularly
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
2. Add and verify the pinned upstream submodule, LICENSE, compatibility manifest,
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
2. Fetch the upstream release tag, resolve its exact commit, and inspect NEWS,
   source changes, test changes, and licensing changes against the previous target.
3. Update the upstream submodule pin and add the new version's compatibility
   manifest. Review inherited exclusions and changed expected failures explicitly.
4. Establish the new GNU reference baseline in the target Linux environment.
5. Implement new features and changed observable behavior. Ask before skipping new
   legacy features or changing established scope. Do not carry exclusions forward
   without checking their applicability.
6. Update NonGNU's compatibility version, help where affected, README, and adapted
   code notices. Verify LICENSE still matches upstream COPYING.
7. Iterate through affected tests and then the full suite. Add differential cases
   for new or changed behavior that the upstream tests do not cover.
8. Verify with Perl 5.22.1 and a current Perl. The minimum does not rise implicitly
   with a new GNU release; discuss any proposed change with the user.
9. Update this guide with the actual repository state, target revision, working
   commands, approved decisions, and verification results. Summarize completion
   and remaining gaps to the user. Commit or release only if requested.
