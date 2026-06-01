#!/bin/bash

# Vex - Git Tree Management
# Manages multiple branches of a repo as independent sibling directories.
#
# Design note: Vex deliberately uses `cp -r` to create full, independent copies
# of your working tree instead of `git worktree`. Each tree is a standalone
# clone-on-disk with its own checked-out branch. This is intentional.

set -e

VERSION="0.1.0"

# --- Paths -------------------------------------------------------------------
# All Vex state lives under $VEX_HOME (override by exporting VEX_HOME).
VEX_HOME="${VEX_HOME:-$HOME/.vex}"
VEX_CONFIG_FILE="$VEX_HOME/config"
VEX_PROJECTS_DIR="$VEX_HOME/projects"

# Populated by load_global_config / load_project.
TREES_BASE_DIR=""
PROJECT_NAME=""
SOURCE_DIR=""
POST_CREATE_HOOK=""

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Config ------------------------------------------------------------------

# Ensure the Vex home directory structure exists.
ensure_vex_home() {
    mkdir -p "$VEX_HOME" "$VEX_PROJECTS_DIR"
}

# Load global config, applying defaults. Sets TREES_BASE_DIR.
load_global_config() {
    ensure_vex_home

    # Defaults (may be overridden by the config file below).
    local trees_base_dir="$VEX_HOME/trees"

    if [[ -f "$VEX_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$VEX_CONFIG_FILE"
    fi

    TREES_BASE_DIR="${trees_base_dir:-$VEX_HOME/trees}"
}

# Path to a project's config file.
project_conf_path() {
    echo "$VEX_PROJECTS_DIR/$1.conf"
}

# Resolve a canonical absolute path (resolves symlinks if the dir exists).
abs_path() {
    ( cd "$1" 2>/dev/null && pwd -P ) || echo "$1"
}

# Detect the current project name from the working directory.
# Matches either a registered project source_dir or a path under TREES_BASE_DIR.
# Prints the project name on success, returns non-zero on failure.
detect_project_name() {
    local cwd
    cwd="$(pwd -P)"

    # 1. cwd matches a registered project's source_dir.
    if [[ -d "$VEX_PROJECTS_DIR" ]]; then
        local conf
        for conf in "$VEX_PROJECTS_DIR"/*.conf; do
            [[ -e "$conf" ]] || continue
            local project_name="" source_dir="" post_create_hook=""
            # shellcheck disable=SC1090
            source "$conf"
            if [[ -n "$source_dir" && "$(abs_path "$source_dir")" == "$cwd" ]]; then
                echo "$project_name"
                return 0
            fi
        done
    fi

    # 2. cwd is somewhere under the trees base dir: trees/<project>/...
    # Canonicalize the base dir so symlinked path components (e.g. macOS
    # /var -> /private/var) don't defeat the prefix match against pwd -P.
    local trees_base
    trees_base="$(abs_path "$TREES_BASE_DIR")"
    if [[ -n "$trees_base" && "$cwd" == "$trees_base"/* ]]; then
        local rest="${cwd#"$trees_base"/}"
        echo "${rest%%/*}"
        return 0
    fi

    return 1
}

# Load a project's config into PROJECT_NAME / SOURCE_DIR / POST_CREATE_HOOK.
# Accepts an optional explicit project name; otherwise auto-detects from cwd.
# shellcheck disable=SC2120  # optional arg, intentionally not passed by current callers
load_project() {
    local name="$1"

    if [[ -z "$name" ]]; then
        if ! name="$(detect_project_name)"; then
            print_error "Could not determine the current Vex project."
            print_info  "Run 'vex init <project_name>' from your repo, or cd into a registered project or tree."
            exit 1
        fi
    fi

    local conf
    conf="$(project_conf_path "$name")"
    if [[ ! -f "$conf" ]]; then
        print_error "No config found for project '$name' ($conf)"
        print_info  "Run 'vex init $name' first."
        exit 1
    fi

    local project_name="" source_dir="" post_create_hook=""
    # shellcheck disable=SC1090
    source "$conf"

    PROJECT_NAME="$project_name"
    SOURCE_DIR="$source_dir"
    POST_CREATE_HOOK="$post_create_hook"

    if [[ -z "$PROJECT_NAME" ]]; then
        print_error "Project config is missing project_name: $conf"
        exit 1
    fi
}

get_project_dir() {
    echo "$TREES_BASE_DIR/$PROJECT_NAME"
}

# Run the configured post-create hook inside a tree directory.
run_post_create_hook() {
    local dir="$1"
    if [[ -n "$POST_CREATE_HOOK" ]]; then
        print_info "Running post-create hook in $dir"
        ( cd "$dir" && eval "$POST_CREATE_HOOK" )
    else
        print_info "No post-create hook configured. Tree ready at: $dir"
        print_info "Set one by editing $(project_conf_path "$PROJECT_NAME")"
    fi
}

# --- Commands ----------------------------------------------------------------

# Initialize a project: register it and create its trees directory.
init() {
    local project_name="$1"

    if [[ -z "$project_name" ]]; then
        print_error "Project name is required"
        echo "Usage: vex init <project_name>"
        exit 1
    fi

    load_global_config

    local conf
    conf="$(project_conf_path "$project_name")"
    local source_dir
    source_dir="$(pwd -P)"

    if [[ -f "$conf" ]]; then
        print_warning "Project '$project_name' is already registered ($conf)"
        read -p "Overwrite its config with the current directory? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Init cancelled"
            exit 0
        fi
    fi

    print_info "Initializing Vex project: $project_name"

    # Write the per-project config file.
    cat > "$conf" << EOF
# Vex project configuration for "$project_name"
# This file is sourced as a shell script.

# Directory whose contents are copied when creating a new tree.
source_dir="$source_dir"

# Command run inside each newly created tree (and on 'switch').
# Use it to open your editor or run setup. Examples:
#   post_create_hook="cursor ."
#   post_create_hook="code ."
#   post_create_hook="\$EDITOR ."
#   post_create_hook="bin/setup && code ."
post_create_hook=""

project_name="$project_name"
EOF
    print_success "Wrote project config: $conf"

    # Create the trees directory for this project only.
    local project_dir="$TREES_BASE_DIR/$project_name"
    mkdir -p "$project_dir"
    print_success "Created trees directory: $project_dir"

    print_success "Project '$project_name' initialized!"
    print_info "Next: edit $conf to set a post_create_hook, then run 'vex add <branch>'"
}

# List all branch directories for the current project.
list() {
    load_global_config
    load_project

    local project_dir
    project_dir=$(get_project_dir)

    if [[ ! -d "$project_dir" ]]; then
        print_error "Project directory does not exist: $project_dir"
        exit 1
    fi

    print_info "Git trees for project: $PROJECT_NAME"
    echo "=================================="

    if [[ -z "$(ls -A "$project_dir" 2>/dev/null)" ]]; then
        print_warning "No branches found"
        return 0
    fi

    for branch_dir in "$project_dir"/*; do
        if [[ -d "$branch_dir" ]]; then
            local branch_name
            branch_name=$(basename "$branch_dir")

            local current_branch
            if [[ -d "$branch_dir/.git" ]]; then
                current_branch=$(cd "$branch_dir" && git branch --show-current 2>/dev/null || echo "no branch")
            else
                current_branch="not a git repo"
            fi

            echo -e "${GREEN}$branch_name${NC} -> ${BLUE}$current_branch${NC}"
        fi
    done
}

# Add a new branch directory (a full copy of the source dir).
add() {
    local branch_name="$1"

    if [[ -z "$branch_name" ]]; then
        print_error "Branch name is required"
        echo "Usage: vex add <branch_name>"
        exit 1
    fi

    load_global_config
    load_project

    local project_dir
    project_dir=$(get_project_dir)
    # Replace "/" with "_" in branch name for directory creation.
    local safe_branch_name="${branch_name//\//_}"
    local branch_dir="$project_dir/$safe_branch_name"

    # If the branch directory already exists, switch to the branch there.
    if [[ -d "$branch_dir" ]]; then
        print_warning "Branch directory already exists: $branch_dir"

        if [[ -d "$branch_dir/.git" ]]; then
            cd "$branch_dir"

            if git show-ref --verify --quiet "refs/heads/$branch_name"; then
                print_info "Branch '$branch_name' exists locally, switching to it..."
                git checkout "$branch_name"
                print_success "Switched to existing branch: $branch_name"
            else
                print_info "Creating new branch '$branch_name' in existing directory..."
                git checkout -b "$branch_name"
                print_success "Created and switched to branch: $branch_name"
            fi

            cd - > /dev/null
            run_post_create_hook "$branch_dir"
            return 0
        else
            print_error "Directory exists but is not a git repository: $branch_dir"
            exit 1
        fi
    fi

    print_info "Adding new branch: $branch_name"

    mkdir -p "$branch_dir"
    print_success "Created branch directory: $branch_dir"

    print_info "Copying files from $SOURCE_DIR ..."
    cp -r "$SOURCE_DIR/." "$branch_dir/"
    print_success "Files copied successfully"

    cd "$branch_dir"

    print_info "Creating git branch: $branch_name"
    if git checkout -b "$branch_name" 2>/dev/null; then
        print_success "Created and switched to branch: $branch_name"
    else
        local exit_code=$?
        if [[ $exit_code -eq 128 ]]; then
            print_warning "Branch '$branch_name' already exists, switching to it..."
            if git checkout "$branch_name" 2>/dev/null; then
                print_success "Switched to existing branch: $branch_name"
            else
                print_error "Failed to switch to branch: $branch_name"
                cd - > /dev/null
                exit 1
            fi
        else
            print_error "Failed to create branch: $branch_name (exit code: $exit_code)"
            cd - > /dev/null
            exit 1
        fi
    fi

    cd - > /dev/null
    print_success "Branch '$branch_name' added successfully!"
    run_post_create_hook "$branch_dir"
}

# Interactively select an existing branch tree and run the post-create hook there.
switch() {
    load_global_config
    load_project

    local project_dir
    project_dir=$(get_project_dir)

    if [[ ! -d "$project_dir" ]]; then
        print_error "Project directory does not exist: $project_dir"
        exit 1
    fi

    local branches=()
    local branch_dirs=()
    for branch_dir in "$project_dir"/*; do
        if [[ -d "$branch_dir" ]]; then
            branches+=("$(basename "$branch_dir")")
            branch_dirs+=("$branch_dir")
        fi
    done

    if [[ ${#branches[@]} -eq 0 ]]; then
        print_warning "No branches found"
        return 0
    fi

    print_info "Available branches:"
    echo "=================="

    for i in "${!branches[@]}"; do
        echo "$((i+1)). ${branches[i]}"
    done

    echo ""
    read -p "Select branch number (1-${#branches[@]}): " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#branches[@]} ]]; then
        print_error "Invalid selection"
        exit 1
    fi

    local selected_branch="${branches[$((selection-1))]}"
    local selected_dir="${branch_dirs[$((selection-1))]}"

    print_info "Selected branch: $selected_branch"
    run_post_create_hook "$selected_dir"
}

# Interactively delete one or more branch directories for the current project.
clean() {
    load_global_config
    load_project

    local project_dir
    project_dir=$(get_project_dir)

    if [[ ! -d "$project_dir" ]]; then
        print_error "Project directory does not exist: $project_dir"
        exit 1
    fi

    local branches=()
    local branch_dirs=()
    for branch_dir in "$project_dir"/*; do
        if [[ -d "$branch_dir" ]]; then
            branches+=("$(basename "$branch_dir")")
            branch_dirs+=("$branch_dir")
        fi
    done

    if [[ ${#branches[@]} -eq 0 ]]; then
        print_warning "No branches found to clean"
        return 0
    fi

    print_info "Available branches to clean:"
    echo "=========================="

    for i in "${!branches[@]}"; do
        echo "$((i+1)). ${branches[i]}"
    done

    echo ""
    print_info "You can select multiple branches by separating numbers with commas or spaces"
    print_info "Examples: '1,3,5' or '1 3 5' or just '2' for a single branch"
    echo ""
    read -p "Select branch number(s) to delete (1-${#branches[@]}): " selection

    local selections=()
    selection="${selection//,/ }"
    read -ra selections <<< "$selection"

    local branches_to_delete=()
    local dirs_to_delete=()
    local invalid_selections=()

    for sel in "${selections[@]}"; do
        [[ -z "$sel" ]] && continue

        if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 ]] && [[ "$sel" -le ${#branches[@]} ]]; then
            local idx=$((sel-1))
            branches_to_delete+=("${branches[$idx]}")
            dirs_to_delete+=("${branch_dirs[$idx]}")
        else
            invalid_selections+=("$sel")
        fi
    done

    if [[ ${#invalid_selections[@]} -gt 0 ]]; then
        print_error "Invalid selection(s): ${invalid_selections[*]}"
        exit 1
    fi

    if [[ ${#branches_to_delete[@]} -eq 0 ]]; then
        print_error "No valid selections made"
        exit 1
    fi

    echo ""
    print_warning "You are about to delete ${#branches_to_delete[@]} branch director(y/ies):"
    for i in "${!branches_to_delete[@]}"; do
        echo "  - ${branches_to_delete[$i]} (${dirs_to_delete[$i]})"
    done

    echo ""
    read -p "Are you sure? This action cannot be undone. (y/N): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local deleted_count=0
        for i in "${!branches_to_delete[@]}"; do
            print_info "Deleting branch directory: ${dirs_to_delete[$i]}"
            if rm -rf "${dirs_to_delete[$i]}"; then
                print_success "Deleted: ${branches_to_delete[$i]}"
                ((deleted_count++))
            else
                print_error "Failed to delete: ${branches_to_delete[$i]}"
            fi
        done

        echo ""
        print_success "Successfully deleted $deleted_count of ${#branches_to_delete[@]} branch director(y/ies)!"
    else
        print_info "Deletion cancelled"
    fi
}

# Delete all branch directories for the current project.
clean_all() {
    load_global_config
    load_project

    local project_dir
    project_dir=$(get_project_dir)

    if [[ ! -d "$project_dir" ]]; then
        print_error "Project directory does not exist: $project_dir"
        exit 1
    fi

    if [[ -z "$(ls -A "$project_dir" 2>/dev/null)" ]]; then
        print_warning "Project directory is already empty: $project_dir"
        return 0
    fi

    local branch_count=0
    for branch_dir in "$project_dir"/*; do
        if [[ -d "$branch_dir" ]]; then
            ((branch_count++))
        fi
    done

    if [[ $branch_count -eq 0 ]]; then
        print_warning "No branches found to clean"
        return 0
    fi

    print_warning "You are about to delete ALL branch directories for project: $PROJECT_NAME"
    print_warning "This will delete $branch_count branch directories from: $project_dir"
    echo ""
    read -p "Are you sure? This action cannot be undone. (y/N): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Deleting all branch directories..."
        rm -rf "${project_dir:?}"/*
        print_success "All branch directories deleted successfully!"
        print_info "Project directory is now empty: $project_dir"
    else
        print_info "Deletion cancelled"
    fi
}

# Track the current branch's remote and hard-reset local to match it.
track() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Not in a git repository"
        exit 1
    fi

    local current_branch
    current_branch=$(git branch --show-current)

    if [[ -z "$current_branch" ]]; then
        print_error "Could not determine current branch"
        exit 1
    fi

    print_info "Tracking remote branch: origin/$current_branch"

    if ! git diff --quiet || ! git diff --cached --quiet; then
        print_warning "You have uncommitted changes:"
        git status --porcelain
        echo ""
        read -p "Do you want to discard these changes and continue? (y/N): " confirm

        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Operation cancelled"
            exit 0
        fi
    fi

    print_info "Pulling latest changes from origin..."
    if ! git pull origin "$current_branch" --rebase; then
        print_error "Failed to pull from origin/$current_branch"
        exit 1
    fi

    print_info "Setting upstream tracking to origin/$current_branch..."
    if ! git branch -u "origin/$current_branch"; then
        print_error "Failed to set upstream tracking"
        exit 1
    fi

    print_info "Resetting to match origin/$current_branch exactly..."
    if ! git reset --hard "origin/$current_branch"; then
        print_error "Failed to reset to origin/$current_branch"
        exit 1
    fi

    print_success "Successfully tracked and reset to origin/$current_branch"
    print_info "Local branch is now synchronized with remote"
}

# Show config locations (and the registered projects).
config() {
    load_global_config
    echo "Vex configuration"
    echo "================="
    echo "VEX_HOME:        $VEX_HOME"
    echo "Global config:   $VEX_CONFIG_FILE"
    echo "Trees base dir:  $TREES_BASE_DIR"
    echo "Projects dir:    $VEX_PROJECTS_DIR"
    echo ""
    echo "Registered projects:"
    local conf found=0
    for conf in "$VEX_PROJECTS_DIR"/*.conf; do
        [[ -e "$conf" ]] || continue
        found=1
        echo "  - $(basename "$conf" .conf)"
    done
    [[ $found -eq 0 ]] && echo "  (none — run 'vex init <project_name>')"
}

# Setup shell integration (function + autocomplete) for the current shell.
shell_setup() {
    local script_path
    if [[ -L "$0" ]]; then
        script_path="$(readlink -f "$0")"
    else
        script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    fi

    local shell_rc=""

    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        shell_rc="$HOME/.bashrc"
    else
        print_error "Unsupported shell: $SHELL"
        print_info "Please manually add the function and autocomplete to your shell configuration"
        return 1
    fi

    print_info "Setting up vex for $SHELL..."

    if ! grep -q "vex()" "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# Vex - Git Tree Management" >> "$shell_rc"
        echo "vex() {" >> "$shell_rc"
        echo "    $script_path \"\$@\"" >> "$shell_rc"
        echo "}" >> "$shell_rc"
        print_success "Added vex function to $shell_rc"
    else
        print_warning "Vex function already exists in $shell_rc"
    fi

    if ! grep -q "_vex_complete" "$shell_rc" 2>/dev/null; then
        if [[ "$SHELL" == *"zsh"* ]]; then
            cat >> "$shell_rc" << 'EOF'

# Vex autocomplete for zsh
_vex_complete() {
    local -a commands

    commands=(
        'init'
        'list'
        'add'
        'switch'
        'clean'
        'clean_all'
        'track'
        'config'
        'shell_setup'
        'version'
        'help'
    )

    compadd "$@" $commands
}

# Ensure completion system is initialized
autoload -Uz compinit && compinit

# Register completion with proper context
compdef _vex_complete vex
EOF
        else
            cat >> "$shell_rc" << 'EOF'

# Vex autocomplete for bash
_vex_complete() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    opts="init list add switch clean clean_all track config shell_setup version help"

    case "${prev}" in
        init|add)
            return 0
            ;;
        *)
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
    esac
}

complete -F _vex_complete vex
EOF
        fi
        print_success "Added vex autocomplete to $shell_rc"
    else
        print_warning "Vex autocomplete already exists in $shell_rc"
    fi

    print_success "Shell setup completed!"
    print_info "Please run 'source $shell_rc' or restart your shell to activate the changes"
}

version() {
    echo "vex $VERSION"
}

help() {
    echo "Vex - Git Tree Management"
    echo "========================="
    echo ""
    echo "Manage multiple branches of a repo as independent sibling directories."
    echo ""
    echo "Usage: vex <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  init <project_name>  - Register the current directory as a Vex project"
    echo "  list                 - List branch directories for the current project"
    echo "  add <branch_name>    - Create a new tree (copy) and check out the branch"
    echo "  switch               - Interactively pick a tree and run its post-create hook"
    echo "  clean                - Interactively delete branch directories (multi-select)"
    echo "  clean_all            - Delete all branch directories for the current project"
    echo "  track                - Track remote branch and reset local to match it"
    echo "  config               - Show config locations and registered projects"
    echo "  shell_setup          - Set up the vex function and autocomplete for your shell"
    echo "  version              - Show the Vex version"
    echo "  help                 - Show this help message"
    echo ""
    echo "Configuration:"
    echo "  Global config:  ${VEX_HOME:-\$HOME/.vex}/config"
    echo "  Project config: ${VEX_HOME:-\$HOME/.vex}/projects/<project_name>.conf"
    echo ""
    echo "Examples:"
    echo "  vex init my-project"
    echo "  vex add feature/new-feature"
    echo "  vex list"
    echo "  vex switch"
}

# --- Dispatch ----------------------------------------------------------------
main() {
    local command="$1"

    case "$command" in
        "init")        init "$2" ;;
        "list")        list ;;
        "add")         add "$2" ;;
        "switch")      switch ;;
        "clean")       clean ;;
        "clean_all")   clean_all ;;
        "track")       track ;;
        "config")      config ;;
        "shell_setup") shell_setup ;;
        "version"|"--version"|"-v") version ;;
        "help"|"--help"|"-h"|"") help ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            help
            exit 1
            ;;
    esac
}

main "$@"
