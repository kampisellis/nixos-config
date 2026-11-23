{
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Allows `nix flake check` to evaluate this host cleanly before hardware-configuration.nix is generated
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  networking = {
    hostName = "laptop";
    networkmanager.enable = true;
  };

  # Bootloader: systemd-boot on a 1 GiB FAT32 ESP (/boot)
  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };

    initrd = {
      systemd.enable = true;
      kernelModules = [ "amdgpu" ];
    };
  };

  # Placeholder label-based mounts using mkDefault so `nixos-generate-config` UUID entries
  # in hardware-configuration.nix override them without conflicts during installation.
  fileSystems = {
    "/" = {
      device = lib.mkDefault "/dev/disk/by-label/NIXROOT";
      fsType = lib.mkDefault "ext4";
    };

    "/boot" = {
      device = lib.mkDefault "/dev/disk/by-label/NIXBOOT";
      fsType = lib.mkDefault "vfat";
      options = lib.mkDefault [
        "fmask=0077"
        "dmask=0077"
      ];
    };

    # On-demand SMB3 automounts from homelab (never block boot, suspend, or shutdown away from LAN)
    "/mnt/roms" = {
      device = "//10.10.10.5/roms";
      fsType = "cifs";
      options = [
        "x-systemd.automount"
        "noauto"
        "x-systemd.device-timeout=5s"
        "x-systemd.mount-timeout=5s"
        "nofail"
        "_netdev"
        "soft"
        "ro"
        "vers=3.1.1"
        "credentials=/var/lib/secrets/smb-homelab.cred"
        "uid=1000"
        "gid=100"
        "file_mode=0444"
        "dir_mode=0555"
      ];
    };

    "/mnt/nas-games" = {
      device = "//10.10.10.5/data/Games";
      fsType = "cifs";
      options = [
        "x-systemd.automount"
        "noauto"
        "x-systemd.device-timeout=5s"
        "x-systemd.mount-timeout=5s"
        "nofail"
        "_netdev"
        "soft"
        "rw"
        "vers=3.1.1"
        "credentials=/var/lib/secrets/smb-homelab.cred"
        "uid=1000"
        "gid=1000"
        "file_mode=0644"
        "dir_mode=0755"
      ];
    };

    "/mnt/nas-data" = {
      device = "//10.10.10.5/data";
      fsType = "cifs";
      options = [
        "x-systemd.automount"
        "noauto"
        "x-systemd.device-timeout=5s"
        "x-systemd.mount-timeout=5s"
        "nofail"
        "_netdev"
        "soft"
        "rw"
        "vers=3.1.1"
        "credentials=/var/lib/secrets/smb-homelab.cred"
        "uid=1000"
        "gid=1000"
        "file_mode=0644"
        "dir_mode=0755"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/secrets 0700 root root -"
  ];

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
    flatpak.enable = false;

    # Hidraw/uaccess rules for 8BitDo Pro 3 (Bluetooth and USB/2.4GHz dongle) and other gamepads
    udev.packages = [ pkgs.game-devices-udev-rules ];
  };

  security.rtkit.enable = true;

  # Native AppImage execution (for ES-DE Frontend) & Feral GameMode for gaming/emulation
  programs = {
    appimage = {
      enable = true;
      binfmt = true;
    };

    gamemode = {
      enable = true;
      enableRenice = true;
    };
  };

  # systemd uaccess rules handle Android ADB devices without requiring a legacy adbusers group.
  users = {
    groups.giannis.gid = 1000;

    users.giannis = {
      isNormalUser = true;
      uid = 1000;
      group = "giannis";
      extraGroups = [
        "audio"
        "gamemode"
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
        dolphin
        fbneo
        flycast
        genesis-plus-gx
        melonds
        mgba
        mupen64plus
        ppsspp
        snes9x
      ]
    ))
    pcsx2
    thunderbird
    discord
    viber
    vscode
    (writeShellScriptBin "agy" ''exec nix run github:numtide/llm-agents.nix#antigravity-cli -- "$@"'')
    chromium
    element-desktop
    firefox
    signal-desktop
    telegram-desktop
    # whatsie # Pulls insecure qtwebengine-5 (use Flatpak, zapzap, or WhatsApp Web PWA)

    jdk11
    # jetbrains-toolbox # upstream 404 in 26.05
    metadata-cleaner
    mpv
    obsidian
    onlyoffice-desktopeditors
    picard
    spotify

    amdgpu_top
    android-tools
    cifs-utils
    kdePackages.gwenview
    kdePackages.kate
    libva-utils
    nfs-utils
    ntfs3g
    nvtopPackages.amd
    peazip
    smartmontools
    testdisk
  ];

  system.autoUpgrade = {
    enable = true;
    flake = "github:kampisellis/nixos-config#laptop";
    flags = [ "--refresh" ];
    dates = "Tue *-*-* 12:00:00";
    operation = "boot";
    allowReboot = false;
    persistent = true;
    randomizedDelaySec = "30min";
  };

  systemd.services.nixos-upgrade.unitConfig.ConditionACPower = true;

  system.stateVersion = "26.05";
}
