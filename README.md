# wl-clipboard-zig

This project implements two command-line Wayland clipboard utilities, `wl-copy`
and `wl-paste`, that let you easily copy data between the clipboard and Unix
pipes, sockets, files and so on.

```bash
# Copy a simple text message:
$ wl-copy Hello world!

# Copy the list of files in ~/Downloads:
$ ls ~/Downloads | wl-copy

# Copy an image:
$ wl-copy < ~/Pictures/photo.png

# Copy the previous command:
$ wl-copy "!!"

# Paste to a file:
$ wl-paste > clipboard.txt

# Sort clipboard contents:
$ wl-paste | sort | wl-copy

# Upload clipboard contents to a pastebin on each change:
$ wl-paste --watch nc paste.example.org 5555
```

# Installing and Building

## Recommended Installation (Nix)

The recommended way to install **wl-clipboard-zig** is via **Nix**, using the flake provided in this repository. This project depends on my fork of **tree_magic**, and the flake pins the correct version automatically. If you try to build this outside of Nix, you will be signing up to solve dependency mismatches that Nix already solved for you.

You have two sane options:

### Option 1: Add to your system or user configuration

If you are using NixOS or Home Manager, add this repository as an input and install the package from the flake outputs. This is the best option if you want reproducible builds and updates without surprises.

### Option 2: Install directly with `nix profile`

For a quick, user-local install:

```bash
nix profile install git+https://forgejo.r0chd.pl/r0chd/wl-clipboard-zig
```

This will build and install `wl-copy` and `wl-paste` into your user profile.

## Installing Nix on non-NixOS distributions

If you are not on NixOS, installing Nix is still trivial and strongly recommended.

* Official installer: [https://nixos.org/download](https://nixos.org/download)
* Portable, zero-root option: [https://github.com/DavHau/nix-portable](https://github.com/DavHau/nix-portable)

`nix-portable` is especially useful on systems where you do not want to touch the host configuration or do not have root access.

Once Nix is available, the flake-based installation above works exactly the same on any distribution.

## Building from source

You *can* build this project manually using Zig. You will need:

* Zig 0.15.2
* wayland-protocols
* wayland-scanner
* libwayland
* My fork of [tree_magic](https://github.com/r0chd/tree_magic)
