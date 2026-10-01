# Camel patch

Camel patch is a self-contained Perl reimplementation of GNU patch. It applies
diff files to original files and aims for exact observable compatibility with a
pinned GNU patch release: command-line parsing, environment variables, patch
parsing and application, prompts, diagnostics, exit statuses, backups, rejects,
and filesystem effects.

The current compatibility target is **GNU patch 2.8**.

## Usage

```sh
perl patch.pl [OPTION]... [ORIGFILE [PATCHFILE]]
```

Options follow GNU patch; see `perl patch.pl --help`. The program is a single
script with no dependencies beyond core Perl.

## Status

Implementation is in progress. See `AGENTS.md` for the maintained development
guide, the current state, and the testing workflow.

## Compatibility target and exclusions

- Supported: unified, normal, context, and Git-style text patches; merge modes;
  `Prereq:` checking; `-D NAME` conditional output; ed-format patches.
- Excluded by agreement: legacy version-control checkout integrations
  (RCS, SCCS, ClearCase, Perforce retrieval via `-g`/`--get`/`PATCH_GET`).
  Camel patch is an offline tool.
- Like GNU patch 2.8, Git binary patches are rejected, not applied.
- Branding differs on purpose: messages say "Camel patch" where GNU patch says
  "GNU patch".

## Requirements

- Perl 5.22.1 or newer; core modules only. The test runners use the system
  Perl in their environment. For minimum-version verification, run the test
  commands in a suitable VM or container whose system Perl meets the requirement.
- Linux is the initial platform.
- No network access at runtime.

## Repository layout

```text
AGENTS.md              maintained contributor and agent guide
patch.pl               the complete implementation
LICENSE                GPL-3.0-or-later, verbatim from GNU COPYING
README.md              this file
compat/2.8.json        compatibility manifest for the pinned target
tools/test.pl          GNU reference suite runner
tools/differential.pl  separate differential-test runner
tests/differential/    project-owned differential cases
gnu-patch/             GNU patch reference checkout pinned to the target release
```

## Testing

Initialize the GNU reference checkout, then run its suite:

```sh
git submodule update --init
perl tools/test.pl                       # test patch.pl
perl tools/test.pl --patch /usr/bin/patch  # GNU reference baseline
```

See `perl tools/test.pl --help` for the full interface. Test-only dependencies
(GNU diff, ed, standard shell utilities) are needed by the suite, not by
`patch.pl`.

### Development checks

Run the configured pre-commit checks with:

```sh
pre-commit run --all-files
```

This checks common repository issues, YAML, spelling, Perl style with
Perl::Critic, and shell scripts with ShellCheck. Pre-commit installs the managed
hook environments; ShellCheck must be installed on the system.

### Extra differential tests

These run separately from GNU's suite:

```sh
perl tools/differential.pl --reference /usr/bin/patch
perl tools/differential.pl --group cli
perl tools/differential.pl --case cli.short-clusters
perl tools/differential.pl --list
```

The differential cases cover CLI and environment behavior, fractional timestamp
handling, `Prereq:`, `-D`, ed edge cases, selected terminal prompts, and quoting
styles in the available C and C.utf8 locales. PTY prompt cases require the
test-only Perl `IO::Pty` module; it is not a runtime dependency.
The reference executable must report GNU patch 2.8, matching the compatibility
manifest. Each case runs both implementations in equivalent isolated directories
and compares exit status, stdout, stderr, file bytes, directory structure, modes,
ownership, symlink targets, hardlink relationships, and selected timestamps.
Arbitrary creation/modification timestamps and inode numbers are not compared,
since those differ between independent runs.

Only invocation-name differences in diagnostics are normalized in the initial
cases. Raw outputs, status records, filesystem snapshots, and both work trees are
retained under `build/differential/run.XXXXXX/`. A mismatch or timeout fails the
run; runner/prerequisite errors exit 2. GNU suite XFAIL declarations do not apply
to these comparisons. See `perl tools/differential.pl --help` for selection and
timeout options.

## License

Licensed under GPL-3.0-or-later; see `LICENSE`. Camel patch is copyright
Canonical Ltd, authored by Paride Legovini
<paride@ubuntu.com>. GNU patch is copyright the Free Software Foundation
and Larry Wall; this project preserves the applicable notices.
