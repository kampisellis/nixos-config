{ config, pkgs, ... }:

{
  nix.package = pkgs.lixPackageSets.stable.lix;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  nixpkgs.config.allowUnfree = true;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  time.timeZone = "Europe/Athens";
  i18n.defaultLocale = "en_US.UTF-8";

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    git vim nano curl wget htop btop tmux just rclone unzip ripgrep fd pciutils usbutils
  ];

  system.stateVersion = "25.11";
}
