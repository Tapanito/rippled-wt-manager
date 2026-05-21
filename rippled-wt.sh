#!/usr/bin/env bash
# Rippled Worktree Manager
# Usage: rw <command> [args]

RW_MAIN_REPO="${HOME}/workspace/rippled"
RW_WT_DIR="${HOME}/workspace/rippled-wt"

_rw_slug() {
    # Replace / and spaces with - for use as directory name
    echo "${1//\//-}" | tr ' ' '-'
}

_rw_path() {
    echo "${RW_WT_DIR}/$(_rw_slug "$1")"
}

_rw_find_wt() {
    local branch="$1"
    local new_path="$(_rw_path "$branch")"
    # Check new convention first
    if [ -d "$new_path" ]; then
        echo "$new_path"
        return 0
    fi
    # Look up actual path from git worktree list (handles legacy naming)
    local wt_path
    wt_path=$(git -C "$RW_MAIN_REPO" worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$branch" '
            /^worktree / { wt=$2 }
            /^branch / && $2==b { print wt; exit }
        ')
    if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
        echo "$wt_path"
        return 0
    fi
    return 1
}

# Resolve worktree path from branch name or current directory
_rw_resolve_wt() {
    local branch="$1"
    if [ -n "$branch" ]; then
        _rw_find_wt "$branch"
        return $?
    fi
    # Detect from current directory
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "Not in a git worktree and no branch specified." >&2
        return 1
    }
    echo "$git_root"
}

# Parse common flags: --mode=<type>, --unity, -j <N>
# Sets: _rw_mode, _rw_unity, _rw_jobs, _rw_clean, _rw_branch
_rw_parse_flags() {
    _rw_mode="Debug"
    _rw_unity=false
    _rw_jobs=$(nproc 2>/dev/null || echo 12)
    _rw_clean=false
    _rw_branch=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --mode=*) _rw_mode="${1#--mode=}" ;;
            --unity)  _rw_unity=true ;;
            --clean)  _rw_clean=true ;;
            -j)       shift; _rw_jobs="$1" ;;
            -j*)      _rw_jobs="${1#-j}" ;;
            -*)       echo "Unknown flag: $1" >&2; return 1 ;;
            *)        _rw_branch="$1" ;;
        esac
        shift
    done
}

# Encode a path into Claude's project directory name (/ → -)
_rw_claude_project_dir() {
    echo "${HOME}/.claude/projects/$(echo "$1" | tr '/' '-')"
}

# Copy local config files from main repo to worktree
_rw_copy_local_configs() {
    local wt_path="$1"

    # .claude/ directory (settings, skills)
    if [ -d "$RW_MAIN_REPO/.claude" ]; then
        mkdir -p "$wt_path/.claude"
        cp -r "$RW_MAIN_REPO/.claude/." "$wt_path/.claude/"
        echo "  Copied .claude/"
    fi

    # Fix paths in settings.local.json to point to this worktree
    if [ -f "$wt_path/.claude/settings.local.json" ]; then
        sed -i "s|${RW_MAIN_REPO}|${wt_path}|g" "$wt_path/.claude/settings.local.json"
        echo "  Fixed .claude/settings.local.json paths"
    fi

    # Symlink Claude project memory so all worktrees share the same memory
    local main_proj_dir="$(_rw_claude_project_dir "$RW_MAIN_REPO")"
    local wt_proj_dir="$(_rw_claude_project_dir "$wt_path")"
    if [ -d "$main_proj_dir/memory" ]; then
        mkdir -p "$wt_proj_dir"
        ln -sfn "$main_proj_dir/memory" "$wt_proj_dir/memory"
        echo "  Symlinked Claude project memory → main repo"
    fi

    # .gitignore_local (used via core.excludesFile)
    if [ -f "$RW_MAIN_REPO/.gitignore_local" ]; then
        cp "$RW_MAIN_REPO/.gitignore_local" "$wt_path/.gitignore_local"
        echo "  Copied .gitignore_local"
    fi

    # .pre-commit-config.yaml (includes local hooks like clang-tidy)
    if [ -f "$RW_MAIN_REPO/.pre-commit-config.yaml" ]; then
        cp "$RW_MAIN_REPO/.pre-commit-config.yaml" "$wt_path/.pre-commit-config.yaml"
        echo "  Copied .pre-commit-config.yaml"
    fi

    # .envrc (activates Nix dev shell via direnv automatically on cd)
    if [ -f "$RW_MAIN_REPO/.envrc" ]; then
        cp "$RW_MAIN_REPO/.envrc" "$wt_path/.envrc"
        direnv allow "$wt_path/.envrc" 2>/dev/null
        echo "  Copied .envrc (direnv allowed)"
    fi
}

# For Debug builds, return NIX_HARDENING_ENABLE with fortify stripped.
# NixOS gcc wrapper injects -D_FORTIFY_SOURCE=3 which warns at -O0.
# For Release builds, return the original value (fortify is useful with -O2).
_rw_hardening_env() {
    local build_type="$1"
    if [ "$build_type" = "Debug" ]; then
        local nih="${NIX_HARDENING_ENABLE:-}"
        nih="${nih//fortify3/}"
        nih="${nih//fortify/}"
        echo "$nih"
    else
        echo "${NIX_HARDENING_ENABLE:-}"
    fi
}

# Run conan install for a worktree
_rw_do_conan() {
    local wt_path="$1"
    local build_type="$2"
    echo "==> conan install (build_type=$build_type)..."
    (cd "$wt_path" && NIX_HARDENING_ENABLE="$(_rw_hardening_env "$build_type")" conan install . \
        --output-folder .build \
        --build missing \
        --settings build_type="$build_type") || return 1
}

# Run cmake configure for a worktree
_rw_do_configure() {
    local wt_path="$1"
    local build_type="$2"
    local unity="$3"
    local build_dir="$wt_path/.build"
    mkdir -p "$build_dir"

    local cmake_args=(
        -G Ninja
        -DCMAKE_TOOLCHAIN_FILE:FILEPATH=build/generators/conan_toolchain.cmake
        -DCMAKE_BUILD_TYPE="$build_type"
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=mold"
        -DCMAKE_C_FLAGS="-gsplit-dwarf -fdebug-prefix-map=$wt_path=."
        -DCMAKE_CXX_FLAGS="-gsplit-dwarf -fdebug-prefix-map=$wt_path=."
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
        -Dxrpld=ON
        -Dtests=ON
    )
    if [ "$unity" = true ]; then
        cmake_args+=(-Dunity=ON)
    fi

    echo "==> cmake configure (build_type=$build_type)..."
    (cd "$build_dir" && NIX_HARDENING_ENABLE="$(_rw_hardening_env "$build_type")" cmake "${cmake_args[@]}" ..) || return 1

    ln -sf .build/compile_commands.json "$wt_path/compile_commands.json"
    echo "Symlinked compile_commands.json -> .build/compile_commands.json"
}

# Run cmake build for a worktree
_rw_do_build() {
    local wt_path="$1"
    local jobs="$2"
    local build_type="$3"
    echo "==> cmake build (-j $jobs)..."
    NIX_HARDENING_ENABLE="$(_rw_hardening_env "$build_type")" cmake --build "$wt_path/.build" -j "$jobs" || return 1
}

rw() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        new|add)
            local do_build=false
            local no_ide=false
            local unity=false
            while [[ "${1:-}" == --* ]]; do
                case "$1" in
                    --build) do_build=true ;;
                    --no-ide) no_ide=true ;;
                    --unity) unity=true ;;
                    *) echo "Unknown flag: $1"; return 1 ;;
                esac
                shift
            done
            local branch="$1"
            local base="${2:-}"
            if [ -z "$branch" ]; then
                echo "Usage: rw new [--build] [--no-ide] [--unity] <branch-name> [base-ref]"
                return 1
            fi
            # If given origin/<name>, treat <name> as the local branch name and
            # origin/<name> as the base
            if [[ "$branch" == origin/* ]]; then
                base="${base:-$branch}"
                branch="${branch#origin/}"
            fi
            local wt_path="$(_rw_path "$branch")"
            mkdir -p "$RW_WT_DIR"
            if git -C "$RW_MAIN_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
                echo "Branch '$branch' already exists, checking it out..."
            elif [ -z "$base" ] && git -C "$RW_MAIN_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                # No base given but a remote tracking branch exists — track it
                base="origin/$branch"
                echo "Creating branch '$branch' tracking '$base'..."
                git -C "$RW_MAIN_REPO" branch --track "$branch" "$base" || return 1
            else
                base="${base:-HEAD}"
                echo "Creating branch '$branch' from '$base'..."
                git -C "$RW_MAIN_REPO" branch "$branch" "$base" || return 1
            fi
            echo "Creating worktree at $wt_path..."
            git -C "$RW_MAIN_REPO" worktree add "$wt_path" "$branch" || {
                # Only delete the branch if we just created it (i.e. base was set by us)
                [ -n "$base" ] && git -C "$RW_MAIN_REPO" branch -d "$branch" 2>/dev/null
                return 1
            }
            echo "Worktree ready at $wt_path"
            echo "Copying local configs..."
            _rw_copy_local_configs "$wt_path"
            if $do_build; then
                local build_args=()
                $unity && build_args+=(--unity)
                rw configure "${build_args[@]}" "$branch"
            else
                echo "Tip: run 'rw make $branch' to build."
            fi
            cd "$wt_path"
            if ! $no_ide; then
                zed .
            fi
            ;;

        cd|go)
            local branch="$1"
            local target_dir
            if [ -z "$branch" ]; then
                target_dir="$RW_MAIN_REPO"
            else
                target_dir="$(_rw_find_wt "$branch")" || {
                    echo "No worktree found for branch '$branch'"
                    return 1
                }
            fi
            cd "$target_dir"
            ;;

        clean)
            _rw_parse_flags "$@" || return 1
            local wt_path
            wt_path="$(_rw_resolve_wt "$_rw_branch")" || return 1
            local build_dir="$wt_path/.build"
            if [ -d "$build_dir" ]; then
                echo "Removing $build_dir..."
                rm -rf "$build_dir"
                rm -f "$wt_path/compile_commands.json"
                echo "Clean."
            else
                echo "Nothing to clean (no .build/ directory)."
            fi
            ;;

        conan)
            _rw_parse_flags "$@" || return 1
            local wt_path
            wt_path="$(_rw_resolve_wt "$_rw_branch")" || return 1
            _rw_do_conan "$wt_path" "$_rw_mode" || return 1
            echo "Conan install done."
            ;;

        configure|build)
            _rw_parse_flags "$@" || return 1
            local wt_path
            wt_path="$(_rw_resolve_wt "$_rw_branch")" || return 1
            local toolchain="$wt_path/.build/build/generators/conan_toolchain.cmake"
            if [ ! -f "$toolchain" ]; then
                echo "Conan toolchain not found, running conan install first..."
                _rw_do_conan "$wt_path" "$_rw_mode" || return 1
            fi
            _rw_do_configure "$wt_path" "$_rw_mode" "$_rw_unity" || return 1
            echo "Configure done at $wt_path/.build"
            ;;

        make)
            _rw_parse_flags "$@" || return 1
            local wt_path
            wt_path="$(_rw_resolve_wt "$_rw_branch")" || return 1

            if $_rw_clean; then
                rm -rf "$wt_path/.build"
                rm -f "$wt_path/compile_commands.json"
                echo "Cleaned .build/"
            fi

            # Conan: run if toolchain is missing
            local toolchain="$wt_path/.build/build/generators/conan_toolchain.cmake"
            if [ ! -f "$toolchain" ]; then
                _rw_do_conan "$wt_path" "$_rw_mode" || return 1
            fi

            # Configure: run if build.ninja is missing
            if [ ! -f "$wt_path/.build/build.ninja" ]; then
                _rw_do_configure "$wt_path" "$_rw_mode" "$_rw_unity" || return 1
            fi

            # Build
            _rw_do_build "$wt_path" "$_rw_jobs" "$_rw_mode" || return 1
            echo "Build complete."
            ;;

        tidy)
            _rw_parse_flags "$@" || return 1
            local wt_path
            wt_path="$(_rw_resolve_wt "$_rw_branch")" || return 1
            local build_dir="$wt_path/.build"

            if [ ! -f "$build_dir/compile_commands.json" ]; then
                echo "No compile_commands.json found. Run 'rw make' first."
                return 1
            fi

            local run_ct
            run_ct=$(command -v run-clang-tidy 2>/dev/null) || {
                echo "run-clang-tidy not found in PATH."
                return 1
            }

            # Find merge-base with develop (or origin/develop)
            local base_ref
            base_ref=$(git -C "$wt_path" merge-base HEAD origin/develop 2>/dev/null \
                    || git -C "$wt_path" merge-base HEAD develop 2>/dev/null) || {
                echo "Could not determine merge-base with develop."
                return 1
            }

            # Get changed C/C++ files
            local -a changed_files=()
            while IFS= read -r f; do
                case "$f" in
                    *.cpp|*.h|*.hpp|*.ipp) changed_files+=("$wt_path/$f") ;;
                esac
            done < <(git -C "$wt_path" diff --name-only --diff-filter=d "$base_ref"...HEAD)

            if [ ${#changed_files[@]} -eq 0 ]; then
                echo "No C/C++ files changed vs develop."
                return 0
            fi

            echo "Running clang-tidy on ${#changed_files[@]} file(s)..."
            local output_file="$wt_path/.build/clang-tidy-output.txt"

            "$run_ct" \
                -j "$_rw_jobs" \
                -p "$build_dir" \
                -quiet \
                -fix \
                -allow-no-checks \
                "${changed_files[@]}" 2>&1 | tee "$output_file"

            echo "Output saved to $output_file"
            ;;

        list|ls)
            git -C "$RW_MAIN_REPO" worktree list
            ;;

        rm|remove)
            local branch="$1"
            if [ -z "$branch" ]; then
                echo "Usage: rw rm <branch-name>"
                return 1
            fi
            local wt_path
            wt_path="$(_rw_find_wt "$branch")" || {
                echo "No worktree found for branch '$branch'"
                return 1
            }
            echo "Removing worktree at $wt_path..."
            git -C "$RW_MAIN_REPO" worktree remove "$wt_path" || \
                git -C "$RW_MAIN_REPO" worktree remove --force "$wt_path"
            read -rp "Also delete branch '$branch'? [y/N] " yn
            if [[ "$yn" == [Yy]* ]]; then
                git -C "$RW_MAIN_REPO" branch -d "$branch" || \
                    git -C "$RW_MAIN_REPO" branch -D "$branch"
            fi
            ;;

        open)
            local branch="$1"
            if [ -z "$branch" ]; then
                echo "Usage: rw open <branch-name>"
                return 1
            fi
            local wt_path
            wt_path="$(_rw_find_wt "$branch")" || {
                echo "No worktree found for branch '$branch'"
                return 1
            }
            cd "$wt_path" && zed .
            ;;

        claude)
            local branch="$1"
            local target_dir
            if [ -z "$branch" ]; then
                target_dir="$RW_MAIN_REPO"
            else
                target_dir="$(_rw_find_wt "$branch")" || {
                    echo "No worktree found for branch '$branch'"
                    return 1
                }
            fi
            cd "$target_dir" && claude
            ;;

        sync)
            # Copy local configs from main repo to all existing worktrees
            local count=0
            while IFS= read -r line; do
                if [[ "$line" == worktree\ * ]]; then
                    local wt_path="${line#worktree }"
                    if [ "$wt_path" != "$RW_MAIN_REPO" ] && [ -d "$wt_path" ]; then
                        echo "Syncing $wt_path..."
                        _rw_copy_local_configs "$wt_path"
                        (( count++ ))
                    fi
                fi
            done < <(git -C "$RW_MAIN_REPO" worktree list --porcelain)
            echo "Done. Synced $count worktrees."
            ;;

        sweep)
            echo "Fetching remote..."
            git -C "$RW_MAIN_REPO" fetch --prune origin 2>/dev/null

            local stale_branches=()
            local stale_paths=()
            local wt_path="" branch=""

            while IFS= read -r line; do
                case "$line" in
                    "worktree "*)
                        wt_path="${line#worktree }"
                        branch=""
                        ;;
                    "branch "*)
                        branch="${line#branch refs/heads/}"
                        ;;
                    "")
                        if [ -n "$branch" ] && [ "$wt_path" != "$RW_MAIN_REPO" ]; then
                            local track
                            track=$(git -C "$RW_MAIN_REPO" for-each-ref \
                                --format='%(upstream:track)' "refs/heads/$branch")
                            if [ "$track" = "[gone]" ]; then
                                stale_branches+=("$branch")
                                stale_paths+=("$wt_path")
                            fi
                        fi
                        wt_path=""
                        branch=""
                        ;;
                esac
            done < <(git -C "$RW_MAIN_REPO" worktree list --porcelain; echo)

            if [ ${#stale_branches[@]} -eq 0 ]; then
                echo "No worktrees with deleted remote branches found."
                return 0
            fi

            echo "Worktrees with deleted remote branches (likely merged):"
            for i in "${!stale_branches[@]}"; do
                echo "  ${stale_branches[$i]}  →  ${stale_paths[$i]}"
            done
            echo
            read -rp "Remove these worktrees and branches? [y/N] " yn
            if [[ "$yn" != [Yy]* ]]; then
                return 0
            fi
            for i in "${!stale_branches[@]}"; do
                echo "Removing ${stale_branches[$i]}..."
                git -C "$RW_MAIN_REPO" worktree remove "${stale_paths[$i]}" 2>/dev/null || \
                    git -C "$RW_MAIN_REPO" worktree remove --force "${stale_paths[$i]}"
                git -C "$RW_MAIN_REPO" branch -D "${stale_branches[$i]}" 2>/dev/null
            done
            git -C "$RW_MAIN_REPO" worktree prune
            echo "Done."
            ;;

        prune)
            git -C "$RW_MAIN_REPO" worktree prune
            echo "Pruned stale worktree entries."
            ;;

        help|*)
            cat <<'EOF'
Rippled Worktree Manager (rw)

  rw new [--build] [--no-ide] [--unity] <branch> [base]
                                     Create branch + worktree
  rw cd [branch]                     cd into worktree (no branch = main repo)
  rw open <branch>                   Open worktree in Zed editor

Build commands (branch is optional — defaults to current directory):

  rw clean [branch]                  Remove .build/ directory
  rw conan [branch] [--mode=Debug|Release]
                                     Run conan install only
  rw configure [branch] [--mode=Debug|Release] [--unity]
                                     Run cmake configure only (auto-runs conan if needed)
  rw make [branch] [--mode=Debug|Release] [--unity] [--clean] [-j N]
                                     Smart build: conan if needed → configure if needed → compile
                                       --clean    Clean .build/ first
                                       --mode=X   Build type (default: Debug)
                                       -j N       Parallel jobs (default: nproc)

  rw tidy [branch] [-j N]            Run clang-tidy on files changed vs develop
  rw build                           Alias for 'rw configure' (backward compat)

Worktree management:

  rw list                            List all rippled worktrees
  rw rm <branch>                     Remove worktree (prompts to delete branch)
  rw claude [branch]                 Start Claude Code in worktree
  rw sync                            Copy local configs (.envrc, .claude/, etc.) to all worktrees
  rw sweep                           Remove worktrees whose remote branch was deleted
  rw prune                           Prune stale worktree metadata

Worktrees are created at: ~/workspace/rippled-wt/<branch-slug>
EOF
            ;;
    esac
}

# Tab completion
_rw_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "new add cd go open clean conan configure build make tidy list ls rm remove claude sync sweep prune help" -- "$cur"))
        return
    fi

    local subcmd="${COMP_WORDS[1]}"

    case "$subcmd" in
        new|add)
            # Count non-flag positional args already typed after the subcommand
            local n_pos=0
            for (( i=2; i<COMP_CWORD; i++ )); do
                [[ "${COMP_WORDS[i]}" != --* ]] && (( n_pos++ ))
            done
            # pos 0 = branch name: local branches (existing checkout) or new name
            # pos 1 = base ref: local + remote branches
            if [ "$n_pos" -eq 0 ]; then
                local branches
                branches=$(git -C "$RW_MAIN_REPO" branch --format='%(refname:short)' 2>/dev/null)
                COMPREPLY=($(compgen -W "$branches" -- "$cur"))
            elif [ "$n_pos" -eq 1 ]; then
                local branches
                branches=$(git -C "$RW_MAIN_REPO" branch -a --format='%(refname:short)' 2>/dev/null)
                COMPREPLY=($(compgen -W "$branches" -- "$cur"))
            fi
            ;;
        cd|go|open|rm|remove|claude)
            [ "$COMP_CWORD" -eq 2 ] || return
            local branches
            branches=$(git -C "$RW_MAIN_REPO" worktree list --porcelain 2>/dev/null \
                | awk '/^branch / { sub("branch refs/heads/",""); print }')
            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
            ;;
        clean|conan|configure|build|make|tidy)
            if [[ "$cur" == --* ]]; then
                local flags="--mode=Debug --mode=Release --unity --clean"
                COMPREPLY=($(compgen -W "$flags" -- "$cur"))
            elif [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-j --mode=Debug --mode=Release --unity --clean" -- "$cur"))
            else
                local branches
                branches=$(git -C "$RW_MAIN_REPO" worktree list --porcelain 2>/dev/null \
                    | awk '/^branch / { sub("branch refs/heads/",""); print }')
                COMPREPLY=($(compgen -W "$branches" -- "$cur"))
            fi
            ;;
    esac
}

complete -F _rw_complete rw
