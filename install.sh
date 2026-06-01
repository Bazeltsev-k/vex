#!/bin/bash

# Vex installer
#
# Usage:
#   Remote:  curl -fsSL https://raw.githubusercontent.com/Bazeltsev-k/vex/main/install.sh | bash
#   Local:   ./install.sh   (run from a checkout of the repo)
#
# Override VEX_REPO_RAW to point at a fork.

set -e

# Raw base URL used to fetch vex.sh when no local copy is found.
VEX_REPO_RAW="${VEX_REPO_RAW:-https://raw.githubusercontent.com/Bazeltsev-k/vex/main}"

VEX_HOME="${VEX_HOME:-$HOME/.vex}"
VEX_BIN_DIR="$VEX_HOME/bin"
VEX_SCRIPT="$VEX_BIN_DIR/vex.sh"
VEX_CONFIG_FILE="$VEX_HOME/config"
VEX_PROJECTS_DIR="$VEX_HOME/projects"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Try to locate a local vex.sh sitting next to this installer.
local_vex_path() {
    local src=""
    # $BASH_SOURCE is reliable when run as a file; empty under `curl | bash`.
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vex.sh"
    fi
    [[ -f "$src" ]] && echo "$src"
}

info "Installing Vex into $VEX_HOME"
mkdir -p "$VEX_BIN_DIR" "$VEX_PROJECTS_DIR"

# 1. Install vex.sh (copy local if present, otherwise download).
LOCAL_VEX="$(local_vex_path || true)"
if [[ -n "$LOCAL_VEX" ]]; then
    info "Using local vex.sh: $LOCAL_VEX"
    cp "$LOCAL_VEX" "$VEX_SCRIPT"
else
    info "Downloading vex.sh from $VEX_REPO_RAW"
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$VEX_REPO_RAW/vex.sh" -o "$VEX_SCRIPT"
    elif command -v wget > /dev/null 2>&1; then
        wget -qO "$VEX_SCRIPT" "$VEX_REPO_RAW/vex.sh"
    else
        error "Neither curl nor wget is available. Cannot download vex.sh."
        exit 1
    fi
fi
chmod +x "$VEX_SCRIPT"
success "Installed vex.sh -> $VEX_SCRIPT"

# 2. Create a default global config if none exists.
if [[ ! -f "$VEX_CONFIG_FILE" ]]; then
    cat > "$VEX_CONFIG_FILE" << EOF
# Vex global configuration
# This file is sourced as a shell script.

# Base directory under which per-project trees are created.
trees_base_dir="\$HOME/.vex/trees"
EOF
    success "Created default config: $VEX_CONFIG_FILE"
else
    info "Config already exists, leaving it untouched: $VEX_CONFIG_FILE"
fi

# 3. Shell integration: add a vex() function and autocomplete.
SHELL_RC=""
if [[ "$SHELL" == *"zsh"* ]]; then
    SHELL_RC="$HOME/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [[ -z "$SHELL_RC" ]]; then
    warning "Unsupported shell: $SHELL"
    info "Add this to your shell config manually:"
    echo "    vex() { $VEX_SCRIPT \"\$@\"; }"
else
    if ! grep -q "vex()" "$SHELL_RC" 2>/dev/null; then
        {
            echo ""
            echo "# Vex - Git Tree Management"
            echo "vex() {"
            echo "    $VEX_SCRIPT \"\$@\""
            echo "}"
        } >> "$SHELL_RC"
        success "Added vex function to $SHELL_RC"
    else
        warning "vex function already exists in $SHELL_RC"
    fi

    if ! grep -q "_vex_complete" "$SHELL_RC" 2>/dev/null; then
        if [[ "$SHELL" == *"zsh"* ]]; then
            cat >> "$SHELL_RC" << 'EOF'

# Vex autocomplete for zsh
_vex_complete() {
    local -a commands
    commands=(init list add switch clean clean_all track config shell_setup version help)
    compadd "$@" $commands
}
autoload -Uz compinit && compinit
compdef _vex_complete vex
EOF
        else
            cat >> "$SHELL_RC" << 'EOF'

# Vex autocomplete for bash
_vex_complete() {
    local cur opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="init list add switch clean clean_all track config shell_setup version help"
    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    return 0
}
complete -F _vex_complete vex
EOF
        fi
        success "Added vex autocomplete to $SHELL_RC"
    else
        warning "vex autocomplete already exists in $SHELL_RC"
    fi
fi

echo ""
success "Vex installed!"
info "Restart your shell or run: source ${SHELL_RC:-your shell config}"
info "Then run 'vex help' to get started."
