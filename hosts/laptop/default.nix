{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "laptop";
  networking.networkmanager.enable = true;

  # Bootloader: GRUB EFI στο /efi (Ιδανικό για το 100MB nvme0n1p1 partition)
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    configurationLimit = 10;
  };
  boot.loader.efi = {
    canTouchEfiVariables = true;
    efiSysMountPoint = "/efi";
  };

  # Filesystems (Διατηρεί ανέπαφο το /home σου στο nvme0n1p2!)
  fileSystems."/" = {
    device = "/dev/nvme0n1p4";
    fsType = "ext4";
  };

  fileSystems."/home" = {
    device = "/dev/nvme0n1p2";
    fsType = "ext4";
  };

  fileSystems."/efi" = {
    device = "/dev/nvme0n1p1";
    fsType = "vfat";
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
  services.fstrim.enable = true;

  # Hardware: ASUS TUF FX505DY (AMD Ryzen 5 3550H + Vega + Radeon RX 560X + RTL8821CE)
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;
  boot.initrd.kernelModules = [ "amdgpu" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.asusd.enable = true;
  services.switcherooControl.enable = true;
  services.power-profiles-daemon.enable = true;

  # Desktop Environment: KDE Plasma 6 & SDDM (Wayland)
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  services.xserver.xkb = {
    layout = "us,gr";
    options = "grp:alt_shift_toggle";
  };

  # Audio (PipeWire), Bluetooth, Printing & AppImage/Flatpak Support
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  services.printing.enable = true;
  services.flatpak.enable = true;
  services.rpcbind.enable = true;

  # Εγγενής εκτέλεση AppImages (για το ES-DE Frontend)
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  users.users.giannis = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "networkmanager" "video" "render" "audio" "lp" "adbusers" ];
  };

  # Όλα τα πακέτα σου (RetroArch με Cores, PCSX2, Browsers, Comms, Media & Tools)
  environment.systemPackages = with pkgs; [
    (retroarch.withCores (cores: with cores; [
      beetle-psx-hw
      bsnes
      flycast
      genesis-plus-gx
      melonds
      mgba
      mupen64plus-next
      snes9x
      fbneo
    ]))
    pcsx2

    librewolf
    chromium
    betterbird
    element-desktop
    vesktop
    telegram-desktop
    signal-desktop
    whatsie

    obsidian
    onlyoffice-desktopeditors
    jetbrains-toolbox
    jdk11
    mpv
    spotify
    picard
    metadata-cleaner

    kate
    gwenview
    peazip
    amdgpu_top
    nvtop
    asusctl
    android-tools
    smartmontools
    testdisk
    ntfs3g
    nfs-utils
  ];
}
