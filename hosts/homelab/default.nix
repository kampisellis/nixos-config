{
  imports = [
    ./hardware-configuration.nix
  ];

  homelab = {
    enable = true;

    # Keep Option B (clean Technitium config) by default; set true only if
    # nixpkgs-unstable provides >= 15 and you choose Option A in docs/RUNBOOK.md.
    technitium.useUnstable = false;

    # Pinned to unstable until stable 26.05 matches the 0.80.x self-hosted NetBird stack.
    netbird = {
      useUnstable = true;
      enableLocalRouteFix = true;
    };

    vaultwarden = {
      enable = true;
      useUnstable = true;
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
