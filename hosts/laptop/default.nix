{ lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Allows `nix flake check` to evaluate this host cleanly before hardware-configuration.nix is generated
  nixpkgs = {
    hostPlatform = lib.mkDefault "x86_64-linux";
    config.allowUnfree = true;
  };

  networking = {
    hostName = "laptop";
    networkmanager.enable = true;
  };

  # Bootloader: GRUB EFI on /efi (kernels reside under /boot on root, fitting the 100 MB ESP)
  boot = {
    loader = {
      systemd-boot.enable = false;
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
        configurationLimit = 10;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/efi";
      };
    };

    initrd.kernelModules = [ "amdgpu" ];
  };

  # Placeholder label-based mounts using mkDefault so `nixos-generate-config` UUID entries
  # in hardware-configuration.nix override them without conflicts during installation.
  # Preserves the existing Arch /home partition (nvme0n1p2) untouched.
  fileSystems = {
    "/" = {
      device = lib.mkDefault "/dev/disk/by-label/NIXLAPTOP";
      fsType = lib.mkDefault "ext4";
    };

    "/home" = {
      device = lib.mkDefault "/dev/disk/by-label/HOME";
      fsType = lib.mkDefault "ext4";
    };

    "/efi" = {
      device = lib.mkDefault "/dev/disk/by-label/EFI";
      fsType = lib.mkDefault "vfat";
      options = lib.mkDefault [
        "fmask=0077"
        "dmask=0077"
      ];
    };
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  # Hardware: ASUS TUF FX505DY (AMD Ryzen 5 3550H + Vega + Radeon RX 560X + RTL8821CE)
  hardware = {
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;

    graphics = {
      enable = true;
      enable32Bit = true;
    };

    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
  };

  services = {
    fstrim.enable = true;
    fwupd.enable = true;
    asusd.enable = true;
    switcherooControl.enable = true;
    power-profiles-daemon.enable = true;

    # Desktop Environment: KDE Plasma 6 & SDDM (Wayland)
    displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
    desktopManager.plasma6.enable = true;

    xserver.xkb = {
      layout = "us,gr";
      options = "grp:alt_shift_toggle";
    };

    # Audio (PipeWire), Printing & Flatpak
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa = {
        enable = true;
        support32Bit = true;
      };
      pulse.enable = true;
      jack.enable = true;
    };

    printing.enable = true;
    flatpak.enable = true;
  };

  security.rtkit.enable = true;

  # Native AppImage execution (for ES-DE Frontend)
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # Match existing Arch UID/GID (1000:1000) to preserve /home ownership — verify with `id` before install.
  # systemd uaccess rules handle Android ADB devices without requiring a legacy adbusers group.
  users = {
    groups.giannis.gid = 1000;

    users.giannis = {
      isNormalUser = true;
      uid = 1000;
      group = "giannis";
      extraGroups = [
        "audio"
        "lp"
        "networkmanager"
        "render"
        "video"
        "wheel"
      ];
    };
  };

  environment.systemPackages = with pkgs; [
    (retroarch.withCores (
      cores: with cores; [
        beetle-psx-hw
        bsnes
        fbneo
        flycast
        genesis-plus-gx
        melonds
        mgba
        mupen64plus
        snes9x
      ]
    ))
    pcsx2

    # betterbird # Install via Flatpak (eu.betterbird.Betterbird) or use thunderbird
    chromium
    element-desktop
    firefox
    signal-desktop
    telegram-desktop
    vesktop
    # whatsie # Pulls insecure qtwebengine-5 (use Flatpak, zapzap, or WhatsApp Web PWA)

    jdk11
    jetbrains-toolbox
    metadata-cleaner
    mpv
    obsidian
    onlyoffice-desktopeditors
    picard
    spotify

    amdgpu_top
    android-tools
    asusctl
    kdePackages.gwenview
    kdePackages.kate
    nfs-utils
    ntfs3g
    nvtopPackages.amd
    peazip
    smartmontools
    testdisk
  ];

  # Target NixOS release for initial laptop installation (after Phase 2 bump to 26.05)
  system.stateVersion = "26.05";
}
