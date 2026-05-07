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

# Encode a path into Claude's project directory name (/ → -)
_rw_claude_project_dir() {
    echo "${HOME}/.claude/projects/$(echo "$1" | tr '/' '-')"
}

# Copy local config files from main repo to worktree
_rw_copy_local_configs() {
    local wt_path="$1"

    # .claude/ directory (settings, skills)
    if [ -d "$RW_MAIN_REPO/.claude" ]; then
        cp -r "$RW_MAIN_REPO/.claude" "$wt_path/.claude"
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
                if $unity; then
                    rw build --unity "$branch"
                else
                    rw build "$branch"
                fi
            else
                echo "Tip: run 'rw build $branch' to set up the CMake build."
            fi
            cd "$wt_path"
            if ! $no_ide; then
                zeditor .
            fi
            ;;

        cd|go)
            local branch="$1"
            if [ -z "$branch" ]; then
                cd "$RW_MAIN_REPO"
                return 0
            fi
            local wt_path
            wt_path="$(_rw_find_wt "$branch")" || {
                echo "No worktree found for branch '$branch'"
                echo "Known worktrees:"
                git -C "$RW_MAIN_REPO" worktree list
                return 1
            }
            cd "$wt_path"
            ;;

        build)
            local unity=false
            if [ "$1" = "--unity" ]; then
                unity=true
                shift
            fi
            local branch="$1"
            local build_type="${2:-Debug}"
            if [ -z "$branch" ]; then
                echo "Usage: rw build [--unity] <branch-name> [Debug|Release]"
                return 1
            fi
            local wt_path
            wt_path="$(_rw_find_wt "$branch")" || {
                echo "No worktree found for branch '$branch'"
                return 1
            }
            local build_dir="$wt_path/.build"
            mkdir -p "$build_dir"
            # conan must run from the worktree root with --output-folder .build
            # conanfile uses cmake_layout() + generators="build/generators", which
            # places files at <output-folder>/build/generators/ = .build/build/generators/
            echo "==> conan install (build_type=$build_type)..."
            (cd "$wt_path" && conan install . \
                --output-folder .build \
                --build missing \
                --settings build_type="$build_type") || return 1
            echo "==> cmake configure (build_type=$build_type)..."
            # Set CCACHE_BASEDIR to the worktree root so absolute include paths are
            # normalized to relative paths — this allows ccache hits across worktrees
            # that have identical file content (common with git worktrees sharing objects).
            local cmake_extra_args=()
            if $unity; then
                cmake_extra_args+=(-Dunity=ON)
            fi
            (cd "$build_dir" && CCACHE_BASEDIR="$wt_path" cmake \
                -DCMAKE_TOOLCHAIN_FILE:FILEPATH=build/generators/conan_toolchain.cmake \
                -GNinja \
                -Dxrpld=ON \
                -Dtests=ON \
                -DCMAKE_BUILD_TYPE="$build_type" \
                -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
                -Duse_mold=ON \
                -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
                -DCMAKE_C_COMPILER_LAUNCHER=ccache \
                "${cmake_extra_args[@]}" \
                ..) || return 1
            echo "Build configured at $build_dir"
            ln -sf .build/compile_commands.json "$wt_path/compile_commands.json"
            echo "Symlinked compile_commands.json -> .build/compile_commands.json"
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
            cd "$wt_path" && zeditor .
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
                                     Create branch + worktree (optionally set up CMake build)
                                       --no-ide   Skip opening Zed editor
                                       --unity    Pass -Dunity=ON to cmake
  rw cd [branch]                     cd into worktree (no branch = main repo)
  rw open <branch>                   Open worktree in Zed editor
  rw build [--unity] <branch> [Debug|Release]
                                     Run conan install + cmake configure
  rw list                            List all rippled worktrees
  rw rm <branch>                     Remove worktree (prompts to delete branch)
  rw claude [branch]                 Start Claude Code in worktree
  rw sweep                           Remove worktrees whose remote branch was deleted
  rw prune                           Prune stale worktree metadata

Worktrees are created at: ~/workspace/rippled-wt/<branch-slug>

Local configs copied from main repo on `rw new`:
  .claude/                   Claude Code settings and skills
  .claude/settings.local.json  (paths rewritten for worktree)
  Claude project memory      (symlinked to main repo's memory)
  .gitignore_local           Local gitignore (core.excludesFile)
  .pre-commit-config.yaml    Pre-commit hooks (incl. clang-tidy)
EOF
            ;;
    esac
}

# Tab completion
_rw_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "new add cd go open build list ls rm remove claude sweep prune help" -- "$cur"))
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
        build)
            case "$COMP_CWORD" in
                2)
                    local branches
                    branches=$(git -C "$RW_MAIN_REPO" worktree list --porcelain 2>/dev/null \
                        | awk '/^branch / { sub("branch refs/heads/",""); print }')
                    COMPREPLY=($(compgen -W "$branches" -- "$cur"))
                    ;;
                3) COMPREPLY=($(compgen -W "Debug Release" -- "$cur")) ;;
            esac
            ;;
    esac
}

complete -F _rw_complete rw
