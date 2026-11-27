{ pkgs, ... }:

let
  powerprofilesctl = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl";

  gamemodePowerStart = pkgs.writeShellScript "gamemode-power-start" ''
    set -euo pipefail
    [ -n "''${XDG_RUNTIME_DIR:-}" ] || exit 0
    state="''${XDG_RUNTIME_DIR}/gamemode-prev-power-profile"
    if [ ! -f "$state" ]; then
      prev="$(${powerprofilesctl} get 2>/dev/null || true)"
      case "$prev" in
        power-saver | balanced | performance)
          printf '%s\n' "$prev" >"$state"
          ;;
      esac
    fi
    ${powerprofilesctl} set performance
  '';

  gamemodePowerEnd = pkgs.writeShellScript "gamemode-power-end" ''
    set -euo pipefail
    [ -n "''${XDG_RUNTIME_DIR:-}" ] || exit 0
    state="''${XDG_RUNTIME_DIR}/gamemode-prev-power-profile"
    target="balanced"
    if [ -f "$state" ]; then
      saved="$(cat "$state" 2>/dev/null || true)"
      rm -f "$state"
      case "$saved" in
        power-saver | balanced | performance)
          target="$saved"
          ;;
      esac
    fi
    ${powerprofilesctl} set "$target"
  '';
in
{
  # Enable in-tree Linux 6.14+ NT synchronization primitives for Proton/Wine
  boot.kernelModules = [ "ntsync" ];
  services.udev.extraRules = ''
    KERNEL=="ntsync", MODE="0666"
  '';

  # Gaming stack (Steam + Heroic) for dual-GPU AMD (Vega 8 + RX 560X) on KDE Plasma Wayland
  programs = {
    steam = {
      enable = true;
      remotePlay.openFirewall = false;
      localNetworkGameTransfers.openFirewall = false;
      extraCompatPackages = with pkgs; [ proton-ge-bin ];
    };

    gamescope.enable = true;

    gamemode = {
      enable = true;
      enableRenice = true;
      settings = {
        general = {
          renice = 10;
          # Always apply performance CPU governor on this dual-AMD laptop instead of iGPU powersave fallback
          igpu_power_threshold = -1;
        };
        # Automatically raise ASUS ACPI platform_profile/TDP via power-profiles-daemon while gaming
        custom = {
          start = "${gamemodePowerStart}";
          end = "${gamemodePowerEnd}";
        };
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
