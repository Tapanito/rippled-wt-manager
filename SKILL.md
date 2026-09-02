---
name: rw
description: Use the `rw` worktree manager to build, clean, configure, or manage rippled worktrees. Use when the user wants to build rippled, create a worktree, clean the build, run conan, or configure cmake.
argument-hint: "[command] [branch] [flags]"
allowed-tools: Bash(rw *), Read
---

# Rippled Worktree Manager (rw)

`rw` is a shell function (sourced from `~/workspace/rippled-wt-manager/rippled-wt.sh` via `~/.bashrc`) that manages git worktrees and builds for the rippled project.

## Build Commands

All build commands auto-detect the worktree from the current directory if no branch is given.

### `rw make` — Smart all-in-one build (most common)

```bash
rw make [branch] [--mode=Debug|Release] [--unity] [--clean] [-j N]
```

- Runs conan install only if the toolchain file is missing
- Runs cmake configure only if `build.ninja` is missing
- Always runs the compile step
- Defaults: `--mode=Debug`, `-j $(nproc)`
- `--clean` removes `.build/` before starting

Examples:
```bash
rw make                          # Debug build in current worktree
rw make --mode=Release           # Release build in current worktree
rw make my-branch                # Debug build for a specific worktree
rw make --clean --mode=Debug     # Clean rebuild
rw make -j 8                    # Limit parallel jobs
```

### `rw clean` — Remove build directory

```bash
rw clean [branch]
```

Removes `.build/` and the `compile_commands.json` symlink.

### `rw conan` — Install dependencies only

```bash
rw conan [branch] [--mode=Debug|Release]
```

Runs `conan install` with the specified build type.

### `rw configure` — CMake configure only

```bash
rw configure [branch] [--mode=Debug|Release] [--unity]
```

Runs cmake configure. Auto-runs conan first if the toolchain is missing.
`rw build` is an alias for `rw configure` (backward compat).

### `rw tidy` — Run clang-tidy on changed files

```bash
rw tidy [branch] [-j N]
```

- Finds C/C++ files changed vs `origin/develop` (merge-base)
- Runs `run-clang-tidy` with `-fix` on those files
- Requires a prior build (needs `compile_commands.json`)
- Output saved to `.build/clang-tidy-output.txt`
- Default `-j $(nproc)`

## Worktree Commands

### `rw new` — Create a new worktree

```bash
rw new [--build] [--no-ide] [--unity] <branch> [base-ref]
```

- Creates a git branch + worktree at `~/workspace/rippled-wt/<branch-slug>`
- Copies `.claude/`, `.envrc`, `.gitignore_local`, `.pre-commit-config.yaml` from main repo
- Symlinks Claude project memory to main repo's memory
- `--build` runs `rw configure` after creation
- `--no-ide` skips opening Zed
- Accepts `origin/<name>` to track a remote branch

### `rw cd [branch]` — Change to worktree directory

No branch = main repo (`~/workspace/rippled`).

### `rw open <branch>` — Open worktree in Zed

### `rw rm <branch>` — Remove a worktree

Prompts to also delete the branch.

### `rw claude [branch]` — Start Claude Code in a worktree

### `rw list` — List all worktrees

### `rw sync` — Copy local configs to all worktrees

### `rw sweep [--builds]` — Remove worktrees whose branch is merged or remote-deleted

Fetches, then offers to remove worktrees/branches merged into `origin/develop` or whose
remote branch was deleted (prompts again per-branch if it has uncommitted changes or
unpushed commits). `--builds` also finds and offers to delete `.build/` directories
untouched for 7+ days across all worktrees.

### `rw prune` — Prune stale worktree metadata

## Build Configuration

The cmake configure step uses these flags (NixOS-specific):
- `-gsplit-dwarf` — split debug info for faster linking
- NixOS `fortify` hardening disabled via `hardeningDisable` in `nix/devshell.nix` (prevents `_FORTIFY_SOURCE` warning in Debug/-O0 builds)
- `-fuse-ld=mold` — fast linker
- `ccache` — compiler caching (via CMAKE_CXX_COMPILER_LAUNCHER)
- Ninja generator
- `xrpld=ON`, `tests=ON`, `CMAKE_EXPORT_COMPILE_COMMANDS=ON`

## Build Mutex

`rw conan`, `rw make`, and `rw tidy` automatically serialise against each other across
all worktrees via a shared `flock` (`~/.cache/rippled-build.lock` by default, override
with `RW_LOCK_FILE`), so two concurrent agents on the same machine never build at once.
Test runs don't go through `rw` and aren't covered — wrap them explicitly:

```bash
rw-lock.sh -- bash -c 'cd .build && ./xrpld -u --unittest=MyTest'
rw-lock.sh --status               # who holds the lock, since when
```

## Directory Layout

- Main repo: `~/workspace/rippled`
- Worktrees: `~/workspace/rippled-wt/<branch-slug>` (slashes become dashes)
- Build dir: `<worktree>/.build/`
- Manager script: `~/workspace/rippled-wt-manager/rippled-wt.sh`

## Important Notes

- `rw` is available as a wrapper executable at `~/.local/bin/rw` for non-interactive shells (e.g. Claude Code agents). Interactive shells source the function from `~/.bashrc` which also enables `rw cd`/`rw new`/`rw claude` to `cd` the calling shell.
- Build commands work from any directory inside a worktree when no branch is specified
- The `--mode` flag defaults to Debug if omitted
