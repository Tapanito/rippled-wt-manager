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

### `rw build <branch> [Debug|Release]`

Runs conan install + cmake configure. Defaults to Debug.

```bash
rw build tapanito/fix-something         # Debug build
rw build tapanito/fix-something Release # Release build
```

This sets up `.build/` with:
- Conan dependencies
- CMake configuration (Ninja, mold linker, ccache)
- `compile_commands.json` (symlinked to worktree root for clang-tidy/LSP)
- `CCACHE_BASEDIR` set to worktree root (enables cross-worktree cache hits)

### `rw cd [branch]`

Navigate to a worktree. No argument = main repo.

### `rw claude [branch]`

Start a Claude Code session in the worktree. No argument = main repo.

### `rw list`

List all worktrees (`git worktree list`).

### `rw rm <branch>`

Remove worktree and optionally delete the branch.

### `rw prune`

Clean up stale worktree metadata.

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
rw new --build tapanito/my-feature      # create worktree + build
# ... make changes ...
cmake --build .build                     # compile
.build/xrpld -u --unittest=MyTest       # test
git add <files> && git commit            # pre-commit hooks run automatically
```

## Important notes for agents

- **Never modify the main repo worktree** (`~/workspace/rippled`) for feature work. Always use `rw new` to create a dedicated worktree.
- **Build before clang-tidy**: the pre-commit clang-tidy hook will fail if `.build/compile_commands.json` doesn't exist.
- **Memory is shared**: all worktrees see the same Claude project memory via symlink. Changes to memory in one worktree are visible in all others.
- **Legacy worktrees**: older worktrees may live at `~/workspace/rippled-<name>` instead of `~/workspace/rippled-wt/<name>`. The `_rw_find_wt` function handles both conventions.
- **Branch naming convention**: use `<username>/<description>` format per CONTRIBUTING.md (e.g. `tapanito/fix-vault-clawback`).
