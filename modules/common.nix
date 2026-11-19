{ pkgs, ... }:

{
  nix = {
    package = pkgs.lixPackageSets.stable.lix;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    # Periodic store deduplication avoids slowing down every build
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  time.timeZone = "Europe/Athens";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    btop
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
