test:
    sudo nixos-rebuild test --flake .#$(hostname)

switch:
    sudo nixos-rebuild switch --flake .#$(hostname)

update:
    nix flake update
    sudo nixos-rebuild switch --flake .#$(hostname)

clean:
    sudo nix-collect-garbage --delete-older-than 14d
