# Rippled Worktree Manager — Agent Guide

This guide is for Claude Code agents working in the rippled codebase.

## Overview

The `rw` command manages git worktrees for the rippled project. Each worktree is an independent checkout with its own working directory, build artifacts, and local config — but they all share the same git object store and hooks.

**Key paths:**
- Main repo: `~/workspace/rippled`
- Worktrees: `~/workspace/rippled-wt/<branch-slug>` (slashes become dashes)
- This script: `~/workspace/rippled-wt-manager/rippled-wt.sh` (sourced from `~/.bashrc`)
- Build dir per worktree: `<worktree>/.build/`
- Claude project memory: `~/.claude/projects/-home-vtumas-workspace-rippled/memory/` (shared across all worktrees via symlink)

## Commands

### `rw new [--build] <branch> [base-ref]`

Creates a branch and worktree. Use `--build` to also run conan + cmake setup.

```bash
rw new tapanito/fix-something           # branch from HEAD
rw new tapanito/fix-something develop   # branch from develop
rw new origin/someone/feature           # track existing remote branch
rw new --build tapanito/new-feature     # create + configure build immediately
```

What it does:
1. Creates the branch (or checks out existing)
2. Creates the worktree at `~/workspace/rippled-wt/<slug>`
3. Copies local configs from main repo (see "What gets copied" below)
4. Optionally runs `rw build`
5. `cd`s into the worktree and opens `zed`

### `rw make [branch] [--mode=Debug|Release] [--unity] [--clean] [-j N]`

Smart build: runs conan install only if the toolchain is missing, cmake configure only
if `build.ninja` is missing, then always compiles. This is the command to use day-to-day.

```bash
rw make                          # Debug build, current worktree
rw make tapanito/fix-something   # Debug build, named worktree
rw make --mode=Release           # Release build
rw make --clean -j 8             # Clean rebuild, 8 jobs
```

### `rw conan [branch] [--mode=Debug|Release]`

Runs `conan install` only.

### `rw configure [branch] [--mode=Debug|Release] [--unity]`

Runs cmake configure only (auto-runs conan first if the toolchain is missing). Sets up:
- CMake configuration (Ninja, mold linker, ccache)
- `compile_commands.json` (symlinked to worktree root for clang-tidy/LSP)

`rw build` is an alias for `rw configure` (kept for backward compat — it does **not**
take a positional `Debug`/`Release` argument, use `--mode=` instead).

### `rw clean [branch]`

Removes `.build/` and the `compile_commands.json` symlink.

### `rw tidy [branch] [-j N]`

Runs `run-clang-tidy -fix` on C/C++ files changed vs the merge-base with `develop`.
Requires a prior build (`compile_commands.json` must exist). Output is saved to
`.build/clang-tidy-output.txt`. If the build was configured with `--unity`, changed
files can be silently skipped (unity batches multiple `.cpp` files per translation
unit) — `rw tidy` warns loudly when it detects this; reconfigure without `--unity` for
reliable results.

### `rw cd [branch]`

Navigate to a worktree. No argument = main repo.

### `rw claude [branch]`

Start a Claude Code session in the worktree. No argument = main repo.

### `rw list`

List all worktrees (`git worktree list`).

### `rw rm <branch>`

Remove worktree and optionally delete the branch.

### `rw sync`

Copy local configs (`.claude/`, `.envrc`, etc. — see "What gets copied" below) from the
main repo to every existing worktree. Use after changing shared config in the main repo.

### `rw sweep [--builds]`

Removes worktrees whose branch has been merged into `origin/develop` or whose remote
branch was deleted, after fetching and prompting for confirmation (and again per-branch
if it has uncommitted changes or unpushed commits). With `--builds`, also finds and
offers to delete `.build/` directories untouched for 7+ days, across all worktrees.

### `rw prune`

Clean up stale worktree metadata.

## Build mutex (concurrent agents)

Multiple agents on this machine may each be working in a different worktree at the same
time. Two simultaneous builds (or full test runs) can exhaust RAM and take the box down,
so heavy operations are serialised through a shared `flock`:

- `rw conan`, `rw make`, and `rw tidy` automatically take the lock — nothing to do.
- Test runs do **not** go through `rw` and are not covered automatically. Wrap them:
  ```bash
  rw-lock.sh --label "tests" -- bash -c 'cd .build && ./xrpld -u <Suites>'
  ```
- `rw-lock.sh --status` shows whether the lock is held and by which worktree/command.
- If a build is blocked waiting on another agent's lock, that's expected — let it wait,
  or run in the background rather than polling.
- `RW_LOCK_FILE` overrides the lock file path (default `~/.cache/rippled-build.lock`).

## What gets copied on `rw new`

The `_rw_copy_local_configs` function copies these from the main repo:

| File/Dir | Purpose |
|---|---|
| `.claude/` | Claude Code settings and skills |
| `.claude/settings.local.json` | Bash permission rules (paths rewritten for worktree) |
| Claude project memory symlink | All worktrees share `~/.claude/projects/-home-vtumas-workspace-rippled/memory/` |
| `.gitignore_local` | Local gitignore via `core.excludesFile` |
| `.pre-commit-config.yaml` | Pre-commit hooks including clang-tidy |
| `.envrc` | Activates Nix dev shell via direnv on `cd` (auto-allowed) |

The `settings.local.json` paths are automatically rewritten from the main repo path to the worktree path using sed.

## Building and running tests

After `rw build <branch>`:

```bash
# Compile
cmake --build .build

# Run all unit tests
.build/xrpld -u

# Run specific test suite
.build/xrpld -u --unittest=<TestSuite>
```

The build uses ccache with `CCACHE_BASEDIR` normalization and `hash_dir=false` + `depend_mode=true` in `~/.config/ccache/ccache.conf`. This means building the same unchanged files in a different worktree is a cache hit.

## Pre-commit hooks

Pre-commit is installed in the main repo's `.git/hooks/` (shared across worktrees). The `.pre-commit-config.yaml` copied to each worktree includes:

- clang-format (C++/proto formatting)
- clang-tidy (static analysis, requires `.build/compile_commands.json`)
- gersemi (CMake formatting)
- prettier (markdown/yaml)
- black (Python)
- cspell (spelling)
- trailing whitespace, EOF fixer, merge conflict check

clang-tidy requires a build to exist (it reads `compile_commands.json` from `.build/`).

## Agent workflow example

Typical flow when starting work on a new feature:

```bash
rw new --build tapanito/my-feature      # create worktree + configure
rw make                                  # compile (also serialised via the build mutex)
# ... make changes ...
rw make                                  # recompile
rw-lock.sh -- bash -c 'cd .build && ./xrpld -u --unittest=MyTest'  # test, under the lock
git add <files> && git commit            # pre-commit hooks run automatically
```

## Important notes for agents

- **Never modify the main repo worktree** (`~/workspace/rippled`) for feature work. Always use `rw new` to create a dedicated worktree.
- **Non-interactive shells** (e.g. this agent) use the `rw` wrapper executable at `~/.local/bin/rw` instead of the sourced shell function. It behaves the same for build commands, but `rw cd`/`rw new`/`rw claude` cannot `cd` the calling shell from a subprocess.
- **Build before clang-tidy**: the pre-commit clang-tidy hook will fail if `.build/compile_commands.json` doesn't exist.
- **Memory is shared**: all worktrees see the same Claude project memory via symlink. Changes to memory in one worktree are visible in all others.
- **Legacy worktrees**: older worktrees may live at `~/workspace/rippled-<name>` instead of `~/workspace/rippled-wt/<name>`. The `_rw_find_wt` function handles both conventions.
- **Branch naming convention**: use `<username>/<description>` format per CONTRIBUTING.md (e.g. `tapanito/fix-vault-clawback`).
