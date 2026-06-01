# Vex

[![Lint](https://github.com/Bazeltsev-k/vex/actions/workflows/lint.yml/badge.svg)](https://github.com/Bazeltsev-k/vex/actions/workflows/lint.yml)

> Git tree management — work on many branches at once, each in its own directory.

Vex manages multiple branches of a repository as independent sibling
directories. Run `vex add <branch>`, and Vex copies your working tree into a
fresh directory, checks out the branch there, and optionally runs a hook of
your choice (open an editor, install deps, whatever you like).

## Why not `git worktree`?

First and foremost, Vex is a tool I built for myself. My repos carry a lot of
files that aren't tracked in git but that I still need in every working copy —
local env files, credentials, scratch data, generated assets, machine-specific
config. `git worktree` doesn't bring any of that along, and symlinking it all
between worktrees just doesn't cut it: links break when files are
recreated, some tools resolve symlinks back to the real path and defeat the
point, and keeping a web of links in sync is more work than it's worth.

Vex sidesteps that by using `cp -r` to make **full, independent copies** of the
working tree. Everything comes along — tracked and untracked, ignored files,
`node_modules`, build artifacts, local config — and each tree is a standalone
directory with its own real `.git`, free to diverge.

Concretely, this works around several `git worktree` limitations:

- **Untracked and ignored files don't transfer.** A new worktree only contains
  tracked files at that commit. Everything untracked or gitignored is left
  behind, so you're back to copying or symlinking by hand. Vex copies the lot.
- **The same branch can't be checked out in two worktrees at once.** Git
  refuses (`fatal: '<branch>' is already checked out at ...`). If you want two
  live working copies on the *same* branch — e.g. two coding sessions or agents
  hacking on one feature in parallel — worktree blocks the second one. Vex
  copies are fully independent, so any number of them can sit on the same
  branch.
- **Everything shares one repository.** Worktrees share a single object store,
  config, hooks, stash, and reflog. A `git gc`, a corrupted repo, a global
  stash, or hook/config changes touch every worktree at once. Each Vex tree has
  its own `.git`, so they're isolated — at the cost of more disk.
- **Some tooling assumes `.git` is a directory.** In a worktree `.git` is a file
  pointing elsewhere, which trips up tools that expect a normal repo layout. A
  Vex tree is just an ordinary checkout, so everything Just Works.
- **A worktree is tethered to its parent.** It can't be relocated freely, and
  removing or moving the main repo breaks it. A Vex tree is self-contained and
  can be moved or deleted on its own.

The trade-off is honest: Vex uses more disk and the copies don't share git
objects. If you want lightweight, shared-`.git` checkouts, use `git worktree`.
Vex is the copy-based alternative for when full isolation is the point.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Bazeltsev-k/vex/main/install.sh | bash
```

Or from a local checkout:

```bash
git clone https://github.com/Bazeltsev-k/vex.git
cd vex
./install.sh
```

> The installer reads `VEX_REPO_RAW` if you want to point it at a fork without
> editing the script.

The installer:

- Installs `vex.sh` to `~/.vex/bin/vex.sh`
- Creates `~/.vex/config` with sensible defaults
- Adds a `vex` shell function and autocomplete to your `~/.zshrc` / `~/.bashrc`

Restart your shell (or `source` your rc file), then run `vex help`.

## Usage

```bash
# Register the current repo as a Vex project
cd ~/code/my-app
vex init my-app

# Create a new tree for a branch (a full copy) and check it out
vex add feature/payments

# List trees for the current project
vex list

# Interactively pick a tree and run its post-create hook again
vex switch

# Delete trees (multi-select), or all of them
vex clean
vex clean_all

# Hard-reset the current branch to match its remote
vex track
```

## Configuration

All Vex state lives under `~/.vex` (override by exporting `VEX_HOME`).

### Global config — `~/.vex/config`

Sourced as a shell script.

```bash
# Base directory under which per-project trees are created.
trees_base_dir="$HOME/.vex/trees"
```

### Per-project config — `~/.vex/projects/<project>.conf`

Created by `vex init`. Also sourced as a shell script.

```bash
# Directory whose contents are copied when creating a new tree.
source_dir="/Users/you/code/my-app"

# Command run inside each newly created tree (and on `vex switch`).
# Use it to open your editor or run setup. Examples:
#   post_create_hook="cursor ."
#   post_create_hook="code ."
#   post_create_hook="$EDITOR ."
#   post_create_hook="bin/setup && code ."
post_create_hook=""

project_name="my-app"
```

The **post-create hook** is how you open your editor of choice — there's no
hardcoded editor. Set it to whatever you want run after a tree is created.

Vex figures out the current project from your working directory: it matches
either a registered project's `source_dir` or a path inside `trees_base_dir`.

## Layout

```
~/.vex/
├── bin/vex.sh                 # the script
├── config                     # global config
├── projects/
│   └── my-app.conf            # per-project config
└── trees/
    └── my-app/
        ├── feature_payments/  # a tree (copy) on branch feature/payments
        └── bugfix_login/
```

## Commands

| Command               | Description                                              |
| --------------------- | -------------------------------------------------------- |
| `init <project_name>` | Register the current directory as a Vex project          |
| `list`                | List branch directories for the current project          |
| `add <branch_name>`   | Create a new tree (copy) and check out the branch        |
| `switch`              | Interactively pick a tree and run its post-create hook   |
| `clean`               | Interactively delete branch directories (multi-select)   |
| `clean_all`           | Delete all branch directories for the current project    |
| `track`               | Track the remote branch and hard-reset local to match it |
| `config`              | Show config locations and registered projects            |
| `shell_setup`         | Set up the `vex` function and autocomplete               |
| `version`             | Show the Vex version                                     |
| `help`                | Show help                                                |

## License

[MIT](LICENSE)
