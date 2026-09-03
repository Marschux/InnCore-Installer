#!/usr/bin/env bash
#
# git update, CMake/make build, build-tree cleanup and the Control-script
# self-update. Sourced via common.sh.

# Bring a checkout to the tip of its current branch. Fast-forward if possible;
# otherwise show what is in the way and offer a hard reset (git pull --ff-only
# just fails silently on local changes / diverged history).
git_update() {   # git_update <repo-dir>
    local dir="$1" branch
    [ -d "$dir/.git" ] || { echo "Not a git checkout: $dir"; return 1; }
    branch="$(gitq "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$branch" ] && [ "$branch" != HEAD ] || { echo "Could not determine branch in $dir"; return 1; }
    # A half-finished merge or rebase from a previous aborted run blocks every
    # git operation below with an unhelpful error.
    gitq "$dir" merge --abort >/dev/null 2>&1 || true
    gitq "$dir" rebase --abort >/dev/null 2>&1 || true
    echo "Fetching origin ($branch) for $dir ..."
    gitq "$dir" fetch --prune origin || { echo "fetch failed."; return 1; }
    local dirty=0
    gitq "$dir" diff --quiet && gitq "$dir" diff --cached --quiet || dirty=1
    if [ "$dirty" -eq 0 ] && gitq "$dir" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
        echo "Updated to origin/$branch (fast-forward)."
        return 0
    fi
    echo ""
    echo "Cannot update cleanly (uncommitted changes and/or diverged history):"
    gitq "$dir" status --short
    echo ""
    read -rp "Discard ALL local changes and hard-reset to origin/$branch? [y/N]: " a
    case "$a" in
        y|Y|j|J)
            gitq "$dir" reset --hard "origin/$branch" && gitq "$dir" clean -fd \
                && echo "Reset to origin/$branch." ;;
        *) echo "Left $dir unchanged." ;;
    esac
}

current_branch() {
    local b
    b="$(git_owner rev-parse --abbrev-ref HEAD 2>/dev/null)"
    { [ -n "$b" ] && [ "$b" != HEAD ] && echo "$b"; } || echo unknown
}

# Refresh the installed Control scripts from the repo checkout (CONTROL_SOURCE_DIR).
# Pulls first when the checkout is a git repo. Fails loudly with the fix when the
# checkout is not readable by the server user (e.g. cloned into a 700 home).
update_control_scripts() {   # update_control_scripts <menu-basename>
    local src="$CONTROL_SOURCE_DIR" f
    if [ "${MENU_RUNNING:-0}" = 1 ]; then submenu_title "⬇️  UPDATE CONTROL SCRIPTS" "$COLOR_CONFIG"; fi
    if [ ! -r "$src/common.sh" ]; then
        echo "Cannot read the repo checkout at:"
        echo "  $src"
        echo "Re-clone it somewhere $USER can read (e.g. under /opt, then"
        echo "'sudo chmod -R a+rX <dir>') and set CONTROL_SOURCE_DIR in"
        echo "  $SCRIPT_DIR/control.conf"
        return 1
    fi
    if gitq "$src" rev-parse --git-dir >/dev/null 2>&1; then
        local branch remote
        branch="$(gitq "$src" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        remote="$(gitq "$src" remote get-url origin 2>/dev/null)"
        echo "Fetching $branch from ${remote:-origin} ..."
        # This checkout is only a distribution point - force it to match the
        # remote so line-ending churn or a stray edit can't block the update.
        if gitq "$src" fetch --prune origin "$branch"; then
            gitq "$src" reset --hard "origin/$branch" \
                && gitq "$src" clean -fd \
                || echo "!! reset failed - installing the files as they are on disk."
        else
            echo "!! git fetch failed - installing the files as they are on disk."
        fi
    else
        echo "!! $src is not a git checkout - installing whatever files are there."
    fi
    # $SCRIPT_DIR is owned by the server user (this menu runs as them), no sudo.
    # Copy every .sh the repo Control dir carries so new helper scripts arrive
    # without a code change here (the other role's menu file is harmless clutter).
    local f n=0
    for f in "$src"/*.sh; do
        [ -f "$f" ] || continue
        if install -m 0755 "$f" "$SCRIPT_DIR/$(basename "$f")"; then n=$((n + 1)); fi
    done
    echo "Control scripts updated from $src ($n files)"
    # Values summaries: 3-way merge against a stored baseline so template changes
    # (new keys, changed defaults, reworded comments) come through, while any key
    # the operator actually tuned keeps its value.
    local tpl dst
    mkdir -p "$SCRIPT_DIR/values"
    for tpl in "$src"/values/*.conf; do
        [ -f "$tpl" ] || continue
        dst="$SCRIPT_DIR/values/$(basename "$tpl")"
        merge_values "$tpl" "$dst" || true
    done
    # Called from inside the menu: the running process still holds the old code,
    # so offer to re-exec. Called as `authmenu update` from a shell: just return.
    [ "${MENU_RUNNING:-0}" = 1 ] || return 0
    echo ""
    read -rp "Restart the menu now to load the new version? [Y/n]: " a
    case "$a" in n|N|no|NO) return 0 ;; *) exec "$SCRIPT_DIR/$1" ;; esac
}

# Records / reports the source commit that was last built, so the build menu can
# say whether a rebuild is due. Keyed per repo basename, stored next to the menu.
build_state_file() { echo "$SCRIPT_DIR/.built-commit.$(basename "$1")"; }

build_hint() {   # build_hint <repo-dir>
    local head built
    head="$(gitq "$1" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$head" ] || return 0
    built=""
    if [ -f "$(build_state_file "$1")" ]; then
        built="$(tr -d '[:space:]' < "$(build_state_file "$1")" 2>/dev/null || true)"
    fi
    if [ -z "$built" ]; then
        echo -e "  ${DIM}Source @ ${head:0:9} - no build recorded yet.${RESET}"
    elif [ "$head" = "$built" ]; then
        echo -e "  ${DIM}Source @ ${head:0:9} - matches last build.${RESET}"
    else
        echo -e "  ${YELLOW}Source @ ${head:0:9} - last build was ${built:0:9}, rebuild recommended.${RESET}"
    fi
}

safe_build() {   # safe_build <build-dir> <repo-dir> <apps-build> <scripts>
    local dir="$1" repo="${2:-}" apps="${3:-all}" scripts="${4:-static}"
    require_path "$repo" || return 1
    run_as_owner mkdir -p "$dir" || return 1
    # No configured build tree (fresh box or after 'Clean build directory') -
    # run CMake first, same flags the installer used.
    if [ ! -f "$dir/CMakeCache.txt" ]; then
        echo "No build tree yet - running CMake configure ($apps, scripts=$scripts)..."
        run_as_owner bash -c "cd '$dir' && cmake '$repo' \
            -DCMAKE_INSTALL_PREFIX='$repo/env/dist' \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DAPPS_BUILD='$apps' \
            -DTOOLS_BUILD=none \
            -DSCRIPTS='$scripts' \
            -DMODULES=static" \
            || { echo "CMake configure failed."; return 1; }
    fi
    run_as_owner bash -c "cd '$dir' && make -j \"\$(nproc)\" && make install" || return 1
    if [ -n "$repo" ]; then gitq "$repo" rev-parse HEAD 2>/dev/null > "$(build_state_file "$repo")" || true; fi
    return 0
}

# Wipe only <acore-dir>/build, after a typed confirmation. Source and Control
# scripts outside build are untouched. (Folded in from the old clean-build.sh.)
clean_build() {   # clean_build <acore-dir>
    local acore="${1:-}" build confirmation
    case "$acore" in
        ''|/) echo "Invalid AzerothCore path."; return 1 ;;
        /*) ;;
        *) echo "The AzerothCore path must be absolute."; return 1 ;;
    esac
    [ -d "$acore" ] || { echo "AzerothCore directory not found: $acore"; return 1; }
    build="$acore/build"

    if [ ! -d "$build" ]; then
        run_as_owner mkdir -p "$build" && echo "Build directory created: $build"
        return 0
    fi

    echo "Only this directory will be cleaned:"
    echo "  $build"
    echo "Source code and Control scripts outside of build are kept."
    read -rp "Type exactly CLEAN to continue: " confirmation
    [ "$confirmation" = CLEAN ] || { echo "Aborted."; return 0; }

    run_as_owner find "$build" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    echo "Build directory cleaned successfully."
}
