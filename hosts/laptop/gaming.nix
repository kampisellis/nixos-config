{ pkgs, ... }:

{
  # Enable in-tree Linux 6.14+ NT synchronization primitives for Proton/Wine
  boot.kernelModules = [ "ntsync" ];
  services.udev.extraRules = ''
    KERNEL=="ntsync", MODE="0666"
  '';

  # Steam-only gaming stack for dual-GPU AMD (Vega 8 + RX 560X) on KDE Plasma Wayland
  programs = {
    steam = {
      enable = true;
      remotePlay.openFirewall = true;
      localNetworkGameTransfers.openFirewall = true;
      extraCompatPackages = with pkgs; [ proton-ge-bin ];
    };

    gamescope.enable = true;

    gamemode = {
      enable = true;
      enableRenice = true;
      settings.general = {
        renice = 10;
        # Always apply performance CPU governor on this dual-AMD laptop instead of iGPU powersave fallback
        igpu_power_threshold = -1;
      };
    };
  };

  # AMD GPU monitoring and fan/power control daemon (lactd) without overdrive kernel params
  services.lact.enable = true;

  environment.systemPackages = with pkgs; [
    heroic
    mangohud
    protontricks
    vulkan-tools
  ];
}
