repo := justfile_directory()

# Shared bash helpers (repo + app mappings + link/unlink/doctor logic).
# `{{repo}}` is exported in each recipe, so functions can rely on $REPO.
bootstrap := '''
set -euo pipefail

declare -A SRC DEST
SRC[nvim]="$REPO/nvim"
DEST[nvim]="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
SRC[tmux]="$REPO/tmux/.tmux.conf"
DEST[tmux]="$HOME/.tmux.conf"
SRC[starship]="$REPO/starship/starship.toml"
DEST[starship]="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"

apps=(nvim tmux starship)

confirm() {
  local prompt="$1" auto_yes="$2" reply
  [ "$auto_yes" = "yes" ] && return 0
  read -r -p "$prompt [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

link_app() {
  local app="$1" auto_yes="${2:-no}"
  local src="${SRC[$app]}" dest="${DEST[$app]}"
  [ -n "$src" ] || { echo "error: unknown app '$app' (expected nvim, tmux, or starship)" >&2; return 1; }

  if [ -L "$dest" ]; then
    if [ "$(readlink -m "$dest")" = "$(readlink -m "$src")" ]; then
      echo "$app: already linked $dest -> $src"
      return 0
    fi
    if ! confirm "$app: $dest is a symlink -> $(readlink "$dest") (not this repo). Replace it?" "$auto_yes"; then
      echo "$app: SKIP — left existing symlink at $dest" >&2
      return 1
    fi
  elif [ -e "$dest" ]; then
    if ! confirm "$app: $dest exists and is not a symlink. Back it up to $dest.bak and replace?" "$auto_yes"; then
      echo "$app: SKIP — left existing file at $dest" >&2
      return 1
    fi
    local backup="$dest.bak"
    [ -e "$backup" ] && backup="$dest.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dest" "$backup"
    echo "$app: backed up existing $dest -> $backup"
  fi

  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
  echo "$app: linked $dest -> $src"
}

unlink_app() {
  local app="$1"
  local dest="${DEST[$app]}"
  [ -n "$dest" ] || { echo "error: unknown app '$app' (expected nvim, tmux, or starship)" >&2; return 1; }
  if [ -L "$dest" ]; then
    rm "$dest"
    echo "$app: unlinked (removed $dest)"
  elif [ -e "$dest" ]; then
    echo "$app: SKIP — $dest exists and is not a symlink" >&2
  else
    echo "$app: nothing to unlink — no symlink at $dest"
  fi
}

doctor_app() {
  local app="$1"
  local src="${SRC[$app]}" dest="${DEST[$app]}"
  printf '%-8s ' "$app"
  if [ ! -e "$src" ]; then
    echo "FAIL  repo file missing: $src"
  elif [ -L "$dest" ] && [ "$(readlink -m "$dest")" = "$(readlink -m "$src")" ]; then
    echo "OK    $dest -> $src"
  elif [ -L "$dest" ]; then
    echo "STALE $dest -> $(readlink "$dest") (target not in dotfiles)"
  elif [ -e "$dest" ]; then
    echo "CONFLICT $dest exists but is not a symlink"
  else
    echo "MISSING $dest"
  fi
}
'''

# Link a dotfile (or all). Pass yes='yes' to auto-confirm overwrites/replacements.
link app='all' yes='no':
  #!/usr/bin/env bash
  export REPO={{repo}}
  {{bootstrap}}
  app="{{app}}"
  auto_yes="{{yes}}"
  if [ "$app" = "all" ]; then
    for a in "${apps[@]}"; do link_app "$a" "$auto_yes"; done
  else
    link_app "$app" "$auto_yes"
  fi

# Unlink a dotfile (or all)
unlink app='all':
  #!/usr/bin/env bash
  export REPO={{repo}}
  {{bootstrap}}
  app="{{app}}"
  if [ "$app" = "all" ]; then
    for a in "${apps[@]}"; do unlink_app "$a"; done
  else
    unlink_app "$app"
  fi

# Diagnose the state of all managed dotfiles
alias status := doctor

doctor:
  #!/usr/bin/env bash
  export REPO={{repo}}
  {{bootstrap}}
  if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "$REPO" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] || branch="unborn (no commits yet)"
    echo "repo:   $REPO ($branch)"
  else
    echo "repo:   $REPO (not a git repo)"
  fi
  for a in "${apps[@]}"; do doctor_app "$a"; done