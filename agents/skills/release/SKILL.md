---
name: release
description: Release Hinagata's packages to Hackage following PVP
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Hinagata Release Skill

Release Hinagata's published packages to Hackage using a single shared
version. This is a `cabal` + Nix flake project: formatting is `nix fmt`, and
the authoritative packaging and check gates are the `just` targets
`release-check` and `check`.

## Versioning Strategy

All published packages share the **same version number** and are released
together. A single annotated git tag `v<version>` marks each release.

The Haskell PVP version format is `A.B.C.D`:

- `A.B` — **major**: breaking API changes (removed/renamed exports, changed
  types, changed semantics).
- `C` — **minor**: backwards-compatible API additions (new exports, new
  modules, new instances).
- `D` — **patch**: bug fixes, documentation, internal-only changes,
  performance improvements.

Increment rules:

- **major**: increment `B`, reset `C` and `D` to 0 (`0.2.0.1` → `0.3.0.0`).
- **minor**: increment `C`, reset `D` to 0 (`0.2.0.1` → `0.2.1.0`).
- **patch**: increment `D` (`0.2.0.1` → `0.2.0.2`).

## Packages (in dependency order)

Publish in this order because of inter-package dependencies — dependencies
first:

1. **hinagata-core** (`hinagata-core/`) — pure fixture plans and
   configuration; no internal deps. Library.
2. **hinagata-postgres** (`hinagata-postgres/`) — transactional PostgreSQL
   execution; depends on `hinagata-core`. Library.
3. **hinagata-cli** (`hinagata-cli/`) — the `hinagata` CLI (fixture planning
   and PostgreSQL lease commands); depends on `hinagata-core` and
   `hinagata-postgres`. Executable-only package.

The following packages are **NOT released** to Hackage:

- **hinagata-workbench-example** (`examples/workbench/`) — test-only
  database-backed service used to exercise the workbench handoff.
- **hinagata-keiro-example** (`examples/keiro-service/`) — test-only Keiro
  consumer used for fixture and lease integration tests.

### Internal dependency bounds (must stay in sync with the version)

The internal `build-depends` entries are currently **unbounded** (e.g. just
`hinagata-core,`). At release time they must carry PVP-compatible bounds that
match the new version. Update every occurrence:

- `hinagata-postgres/hinagata-postgres.cabal`: `hinagata-core ^>=<version>`
  in the `library`, the `test-suite`, **and both benchmarks**.
- `hinagata-cli/hinagata-cli.cabal`: `hinagata-core ^>=<version>` and
  `hinagata-postgres ^>=<version>` in the `executable` **and** the
  `test-suite`.

Use `grep -n 'hinagata-core\|hinagata-postgres' <cabal>` to find every site;
do not miss the test-suite/benchmark stanzas.

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — forces the bump level.
- If omitted, determine the bump level from the changes (step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from any package's `.cabal` file (all published
  packages share it; confirm they match).
- Find the latest git tag matching `v*` (`git tag --list 'v*' | sort -V | tail -1`).
  If there are no tags, this is the **first release** — treat the whole
  history as the change set.
- Run `git log --oneline <last-tag>..HEAD` (or the full log on a first
  release) to list commits.
- If there are no commits since the last tag, report that there is nothing to
  release and stop.

Present a summary: current version, last release tag (or "none — first
release"), commit count, and which package directories changed.

### 2. Determine the next version using PVP

- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- Otherwise analyze the commits (Conventional Commits are used in this repo —
  see global CLAUDE.md):
  - `feat!:` / `BREAKING CHANGE:` / "remove", "rename", type changes → major.
  - `feat:` / new exports or modules → minor.
  - `fix:`, `docs:`, `refactor:`, `chore:`, `test:`, internal-only → patch.
- On a first release from `0.1.0.0`, confirm with the user whether `0.1.0.0`
  is the intended first published version or whether to bump first.
- Present the proposed bump and resulting version and **ask the user to
  confirm** before making any edits.

### 3. Update versions, bounds, and changelogs

**Versions** — edit every published package's cabal to the new version:

- `hinagata-core/hinagata-core.cabal`
- `hinagata-postgres/hinagata-postgres.cabal`
- `hinagata-cli/hinagata-cli.cabal`

(A package may already have been bumped mid-cycle; verify all three are at
the target version before committing.)

**Internal bounds** — set the `^>=<version>` bounds described under "Internal
dependency bounds" above, in every library/executable/test-suite/benchmark
stanza.

**Changelogs** — Hinagata has no CHANGELOGs yet. For each published package,
create (or update) `<pkg-dir>/CHANGELOG.md` with a section for the new version
dated today (`YYYY-MM-DD`), plus a root `CHANGELOG.md`. Group entries under
only the categories that apply:

- **Breaking Changes** (major)
- **New Features** (minor or major)
- **Bug Fixes**
- **Other Changes** (docs, refactoring, tooling)

If a package already has a CHANGELOG with an "Unreleased" section, fold that
content into the new version section.

Show the user **all** changes (versions, bounds, changelogs) for review before
committing.

> Packaging hygiene: `cabal check` currently warns because the cabal files
> lack `homepage`, `bug-reports`, and a `source-repository head` stanza. These
> are warnings, not errors, and do not block upload — but offer to add them
> (pointing at the GitHub repo) on the first release.

### 4. Verify (format, build, test, check gates)

Run from the repo root and stop on the first failure:

- `nix fmt` — apply formatting. (CI equivalent: `just fmt-check`, i.e.
  `nix fmt -- --ci`.)
- `just release-check` — the authoritative packaging gate: builds every
  package's `cabal sdist` in an isolated workspace, then builds, tests, and
  runs haddock against the unpacked sources, plus the CLI and
  migration/verification smoke. This is what proves the tarballs that will go
  to Hackage actually work.
- `just check` — full gate: `check-conventions`, `check-docs`, the unit/CLI
  tests, `fmt-check`, all `cabal sdist`s, and `nix flake check` (treefmt +
  pre-commit).

Notes:

- `nix flake check` reads the **git tree**, so `git add` any newly created
  files (e.g. new `CHANGELOG.md`s) before running it or they won't be seen.
- Postgres/CLI tests spin up a local cluster via `scripts/test-postgres.sh`;
  if they can't run in this environment, say so and do not silently skip them.

If any gate fails, fix it before proceeding — do not continue to commit.

### 5. Commit, tag, and push

- Stage the modified `.cabal` files and all `CHANGELOG.md` files.
- Create a single Conventional Commits commit: `chore(release): <version>`.
  The body summarizes the release and justifies the chosen bump.
- Create a single annotated tag: `git tag -a v<version> -m "Release <version>"`.
- Push: `git push && git push --tags`.

### 6. Publish to Hackage (in dependency order)

For EACH published package, in order **hinagata-core → hinagata-postgres →
hinagata-cli**:

1. `cd <pkg-dir>`.
2. `cabal check` — verify no packaging errors (warnings about
   homepage/source-repository are acceptable).
3. `cabal sdist` then `cabal upload --publish <tarball-path>` — publish the
   source distribution.
4. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`
   then `cabal upload --publish --documentation <docs-tarball-path>` — publish
   docs. (`hinagata-cli` is executable-only; its haddock may be sparse —
   upload it anyway unless it produces nothing.)
5. Report the Hackage URL: `https://hackage.haskell.org/package/<pkg>-<version>`.

After all packages publish, present a summary table:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| hinagata-core | X.Y.Z.W | https://hackage.haskell.org/package/hinagata-core-X.Y.Z.W |
| hinagata-postgres | X.Y.Z.W | https://hackage.haskell.org/package/hinagata-postgres-X.Y.Z.W |
| hinagata-cli | X.Y.Z.W | https://hackage.haskell.org/package/hinagata-cli-X.Y.Z.W |

### 7. Create the GitHub release

After all Hackage uploads succeed, create the release for the tag:

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Packages

| Package | Hackage |
|---------|---------|
| hinagata-core | https://hackage.haskell.org/package/hinagata-core-X.Y.Z.W |
| hinagata-postgres | https://hackage.haskell.org/package/hinagata-postgres-X.Y.Z.W |
| hinagata-cli | https://hackage.haskell.org/package/hinagata-cli-X.Y.Z.W |

## What's Changed

<changelog entries for this version from the root CHANGELOG.md>
EOF
)"
```

Use the root `CHANGELOG.md` entries as the notes body, include the Hackage
links table, and report the GitHub release URL when done.

## Important

- Always ask the user to confirm the version bump and all changelog/bounds
  edits before committing.
- Always publish in dependency order: hinagata-core → hinagata-postgres →
  hinagata-cli.
- Keep internal `^>=` bounds in sync with the version in every stanza
  (library, executable, test-suite, benchmark).
- Never skip `just release-check`, `just check`, or `nix flake check`.
- If any step fails, stop and report the error rather than continuing.
- If a Hackage upload fails, do NOT continue uploading packages that depend on
  it (a broken `hinagata-core` upload blocks `hinagata-postgres` and
  `hinagata-cli`).
- Run `nix fmt` before committing, and `git add` new files before
  `nix flake check`.
- The commit and tag are created only AFTER user approval of all changes.
