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
    uptime-kuma.enable = true;
    ntfy.enable = true;
    searxng.enable = true;
  };

  # Fixed to the NixOS release originally installed on this host — NEVER change on upgrades.
  system.stateVersion = "25.11";
}
