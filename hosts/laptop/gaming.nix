{ pkgs, ... }:

{
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
    };
  };

  # AMD GPU monitoring and fan/power control daemon (lactd) without overdrive kernel params
  services.lact.enable = true;

  environment.systemPackages = with pkgs; [
    mangohud
    vulkan-tools
  ];
}
