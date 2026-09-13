# dotfiles

Personal config for `nvim`, `tmux`, and `starship`, managed as symlinks into `$HOME` via a [`justfile`](./justfile).

## Layout

```
nvim/               -> ~/.config/nvim
tmux/.tmux.conf     -> ~/.tmux.conf
starship/starship.toml -> ~/.config/starship.toml
```

## Requirements

Symlinking is driven by [`just`](https://github.com/casey/just), a command runner (like `make`, but simpler). Install it with whichever you have available:

```sh
# Nix
nix profile install nixpkgs#just

# Homebrew (macOS/Linux)
brew install just

# apt (Debian/Ubuntu, recent releases)
sudo apt install just

# Cargo
cargo install just

# Official install script (no package manager needed)
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
```

## Setup on a new machine

Clone the repo to `~/.dotfiles`:

```sh
git clone git@github.com:wypratama/dotfiles.git ~/.dotfiles
```

Then link everything:

```sh
cd ~/.dotfiles
just link all
```

## Usage

```sh
just link nvim        # symlink one app
just link all          # symlink everything
just link nvim yes     # same, but auto-confirm any overwrite/replace prompts

just unlink tmux        # remove one symlink
just unlink all          # remove all symlinks

just status             # (alias for doctor) show the state of every managed symlink
just doctor
```

`link` refuses to clobber a real (non-symlink) file or an unrelated existing symlink without asking first — it'll prompt to back the old one up to `<file>.bak` before replacing it. Pass `yes` as the second argument to skip the prompts (still backs up).
