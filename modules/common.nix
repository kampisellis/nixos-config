{ pkgs, ... }:

{
  nix = {
    package = pkgs.lixPackageSets.stable.lix;
    channel.enable = false;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    # Periodic store deduplication avoids slowing down every build
    optimise = {
      automatic = true;
      dates = [ "Sun *-*-* 06:00:00" ];
    };

    gc = {
      automatic = true;
      dates = "Sun *-*-* 05:00:00";
      options = "--delete-older-than 14d";
    };
  };

  time.timeZone = "Europe/Athens";
  i18n.defaultLocale = "en_US.UTF-8";

  # Bound persistent journald disk usage across both hosts
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=1month
  '';

  environment.systemPackages = with pkgs; [
    curl
    dnsutils
    fd
    git
    htop
    just
    nano
    nvd
    openssl
    pciutils
    rclone
    ripgrep
    tmux
    unzip
    usbutils
    vim
    wget
  ];
}
