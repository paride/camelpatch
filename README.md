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

- Perl 5.22.1 or newer; core modules only.
- Linux is the initial platform.
- No network access at runtime.

## Repository layout

```text
AGENTS.md              maintained contributor and agent guide
patch.pl               the complete implementation
LICENSE                GPL-3.0-or-later, verbatim from GNU COPYING
README.md              this file
compat/2.8.json        compatibility manifest for the pinned target
tools/test.pl          test suite runner
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

## License

Licensed under GPL-3.0-or-later; see `LICENSE`. Camel patch is copyright
Canonical Ltd, authored by Paride Legovini
<paride@ubuntu.com>. GNU patch is copyright the Free Software Foundation
and Larry Wall; this project preserves the applicable notices.
