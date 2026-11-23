{
  imports = [
    ./hardware-configuration.nix
  ];

  homelab = {
    enable = true;

    # Track stable nixpkgs for Technitium DNS by default.
    technitium.useUnstable = false;

    # Pinned to unstable until stable 26.05 matches the 0.80.x self-hosted NetBird stack.
    netbird = {
      useUnstable = true;
      enableLocalRouteFix = true;
    };

    vaultwarden = {
      enable = true;
      useUnstable = false;
    };

    immich = {
      enable = true;
      useUnstable = true;
    };

    radicale.enable = true;
    couchdb.enable = true;
    lidarr.enable = true;
    ntfy.enable = true;
    searxng.enable = true;
  };

  # Updates are driven by the weekly stable-nixpkgs GitHub PR + manual `just diff`/`test`/`switch`.
  system.autoUpgrade.enable = false;

  # Fixed to the NixOS release originally installed on this host — NEVER change on upgrades.
  system.stateVersion = "25.11";
}
