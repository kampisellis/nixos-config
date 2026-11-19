# Default target host is the local hostname; override via `just build laptop`
default_host := `hostname`

# List available recipes
default:
    @just --list

# Evaluate flake and all host configurations without building toplevels
check:
    nix flake check --no-build --show-trace

# Check formatting and run Nix linters (statix, deadnix)
lint:
    nix build .#checks.x86_64-linux.formatting .#checks.x86_64-linux.statix .#checks.x86_64-linux.deadnix --no-link

# Format all Nix files in-place using RFC-166 nixfmt
fmt:
    nix fmt .

# Build system configuration into ./result without activating
build host=default_host:
    nixos-rebuild build --flake .#{{host}}

# Compare ./result against the currently running system using nvd
diff host=default_host: (build host)
    nvd diff /run/current-system ./result

# Temporarily activate configuration (reverted automatically on reboot)
test host=default_host:
    sudo nixos-rebuild test --flake .#{{host}}

# Permanently switch system and update bootloader entry
switch host=default_host:
    sudo nixos-rebuild switch --flake .#{{host}}

# Safe stable update: update ONLY nixpkgs input, build, and show package diff (NEVER auto-switch)
update host=default_host:
    nix flake update nixpkgs
    just diff {{host}}

# Explicit unstable update: use intentionally and inspect DB-backed services (Immich/Vaultwarden)
update-unstable host=default_host:
    nix flake update nixpkgs-unstable
    just diff {{host}}

# Print the auto-generated Markdown services table from homelab.services registry
services-table:
    @cat $(nix build .#services-table --no-link --print-out-paths)

# Remove Nix store garbage older than 14 days
clean:
    sudo nix-collect-garbage --delete-older-than 14d
