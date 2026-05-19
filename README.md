# rw — Rippled Worktree Manager

A shell function that manages [git worktrees](https://git-scm.com/docs/git-worktree) and builds for the [rippled](https://github.com/XRPLF/rippled) (XRP Ledger) project. Each worktree gets its own checkout, build directory, and local config — but they all share one git object store and a single ccache.

## Setup

1. Clone this repo:
   ```bash
   git clone git@github.com:Tapanito/rippled-wt-manager.git ~/workspace/rippled-wt-manager
   ```

2. Source the script from your shell rc (`~/.bashrc` or `~/.zshrc`):
   ```bash
   source ~/workspace/rippled-wt-manager/rippled-wt.sh
   ```

3. Make sure your main rippled repo lives at `~/workspace/rippled`. If it's elsewhere, set `RW_MAIN_REPO` before sourcing.

### Prerequisites

- **Conan 2** — C++ dependency manager
- **CMake** + **Ninja** — build system
- **ccache** — compiler cache (see [ccache config](#ccache-configuration) below)
- **mold** — fast linker
- **direnv** + **Nix** (optional) — `rw` copies `.envrc` to worktrees so `use_flake` activates automatically

## Quick start

```bash
# Create a worktree and build in one shot
rw new --build tapanito/my-feature

# Or step by step
rw new tapanito/my-feature develop     # create worktree from develop
rw make                                 # build (auto-detects worktree from PWD)

# Run tests
.build/xrpld --unittest=MyTestSuite
```

## Commands

### Building

All build commands auto-detect the worktree from your current directory. You can also pass a branch name explicitly.

| Command | What it does |
|---|---|
| `rw make [branch] [flags]` | Smart build: conan → configure → compile (skips steps already done) |
| `rw clean [branch]` | Remove `.build/` directory |
| `rw conan [branch] [--mode=...]` | Run conan install only |
| `rw configure [branch] [--mode=...] [--unity]` | Run cmake configure only (auto-runs conan if needed) |
| `rw tidy [branch] [-j N]` | Run clang-tidy on files changed vs `develop` |

**Flags for build commands:**

| Flag | Default | Description |
|---|---|---|
| `--mode=Debug\|Release` | `Debug` | Build type |
| `--unity` | off | Enable unity (jumbo) builds |
| `--clean` | off | Clean `.build/` before building (make only) |
| `-j N` | `$(nproc)` | Parallel jobs |

**Examples:**
```bash
rw make                              # Debug build, all cores
rw make --mode=Release               # Release build
rw make --clean -j 8                 # Clean rebuild, 8 jobs
rw make tapanito/other-branch        # Build a different worktree
rw tidy                              # clang-tidy changed files
```

### Worktree management

| Command | What it does |
|---|---|
| `rw new [--build] [--no-ide] [--unity] <branch> [base]` | Create branch + worktree |
| `rw cd [branch]` | cd into worktree (no arg = main repo) |
| `rw open <branch>` | Open worktree in Zed |
| `rw claude [branch]` | Start Claude Code in worktree |
| `rw rm <branch>` | Remove worktree (prompts to delete branch) |
| `rw list` | List all worktrees |
| `rw sync` | Copy local configs to all existing worktrees |
| `rw sweep` | Remove worktrees whose remote branch was deleted |
| `rw prune` | Prune stale worktree metadata |

**`rw new` examples:**
```bash
rw new tapanito/fix-something               # branch from HEAD
rw new tapanito/fix-something develop        # branch from develop
rw new origin/someone/feature                # track existing remote branch
rw new --build --no-ide tapanito/feature     # create + build, skip editor
```

## Directory layout

```
~/workspace/
├── rippled/                    # Main repo (develop branch)
├── rippled-wt/                 # Worktrees live here
│   ├── tapanito-my-feature/    #   branch: tapanito/my-feature
│   │   ├── .build/             #     build artifacts
│   │   ├── .envrc              #     nix dev shell (copied from main)
│   │   └── ...                 #     source code
│   └── tapanito-other-thing/   #   branch: tapanito/other-thing
└── rippled-wt-manager/         # This repo
```

## What `rw new` copies

When creating a worktree, these files are copied from the main repo:

| File | Purpose |
|---|---|
| `.claude/` | Claude Code settings and skills |
| `.claude/settings.local.json` | Paths rewritten to point to worktree |
| Claude project memory | Symlinked so all worktrees share memory |
| `.gitignore_local` | Local gitignore (`core.excludesFile`) |
| `.pre-commit-config.yaml` | Pre-commit hooks (clang-tidy, formatters) |
| `.envrc` | Activates Nix dev shell via direnv |

## CMake flags

The configure step uses these flags:

| Flag | Purpose |
|---|---|
| `-gsplit-dwarf` | Split debug info for faster linking |
| `-fdebug-prefix-map=$wt_path=.` | Normalize debug paths for ccache sharing |
| `-fuse-ld=mold` | Fast linker |
| `ccache` | Compiler cache (`CMAKE_CXX_COMPILER_LAUNCHER`) |
| Ninja | Build generator |

### NixOS: fortify hardening

On NixOS, the gcc wrapper injects `-D_FORTIFY_SOURCE=3` which warns in Debug builds (`-O0`). `rw` automatically strips `fortify` from `NIX_HARDENING_ENABLE` for Debug builds only — Release builds keep fortify enabled.

## ccache configuration

Recommended `~/.config/ccache/ccache.conf` for cross-worktree cache sharing:

```ini
max_size = 20G
base_dir = /home/<you>/workspace
sloppiness = include_file_mtime
hash_dir = false
depend_mode = true
```

| Setting | Why |
|---|---|
| `base_dir` | Normalizes absolute paths to relative — worktrees at different paths hash the same |
| `hash_dir = false` | Don't include CWD in hash |
| `sloppiness = include_file_mtime` | git checkout changes timestamps; ignore them |
| `depend_mode = true` | Skip double-preprocessing for faster lookups |

Combined with `-fdebug-prefix-map` in the cmake flags, this means building unchanged files in a different worktree is a cache hit.

## Tab completion

Bash tab completion is included. Branch names auto-complete for all commands.
