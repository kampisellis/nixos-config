{
  lib,
  nixpkgs-unstable,
  pkgs,
  pkgs-unstable,
  ...
}:

let
  # Dynamically apply the patched RGB-only EDID only when a Dell P2723D is attached on HDMI-A-1,
  # leaving any other HDMI sink (projectors, TVs, other monitors) on its native EDID + HDMI Audio.
  hdmiEdidOverride = pkgs.writeShellApplication {
    name = "hdmi-edid-override";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      lock_file="/run/hdmi-edid-override.lock"
      cooldown_file="/run/hdmi-edid-override.last-apply"

      exec 9>"$lock_file"
      flock -x 9

      connector_dir=""
      for candidate in /sys/class/drm/card*-HDMI-A-1; do
        if [[ -d "$candidate" ]]; then
          connector_dir="$candidate"
          break
        fi
      done

      if [[ -z "$connector_dir" ]]; then
        exit 0
      fi

      pci_path="$(readlink -f "$connector_dir/device/device" || true)"
      pci_addr=""
      if [[ -n "$pci_path" ]]; then
        pci_addr="$(basename "$pci_path")"
      fi

      debugfs_dir=""
      if [[ -n "$pci_addr" && -d "/sys/kernel/debug/dri/$pci_addr/HDMI-A-1" ]]; then
        debugfs_dir="/sys/kernel/debug/dri/$pci_addr/HDMI-A-1"
      else
        card_name="$(basename "$connector_dir")"
        card_num="''${card_name#card}"
        card_num="''${card_num%%-*}"
        if [[ -d "/sys/kernel/debug/dri/$card_num/HDMI-A-1" ]]; then
          debugfs_dir="/sys/kernel/debug/dri/$card_num/HDMI-A-1"
        fi
      fi

      if [[ -z "$debugfs_dir" ]]; then
        exit 0
      fi

      edid_override="$debugfs_dir/edid_override"
      trigger_hotplug="$debugfs_dir/trigger_hotplug"

      if [[ ! -w "$edid_override" ]]; then
        exit 0
      fi

      if [[ "''${1:-}" == "--reset" ]]; then
        printf 'reset' >"$edid_override"
        rm -f "$cooldown_file"
        exit 0
      fi

      status="$(cat "$connector_dir/status" 2>/dev/null || true)"

      if [[ "$status" == "disconnected" ]]; then
        printf 'reset' >"$edid_override"
        rm -f "$cooldown_file"
        exit 0
      fi

      if [[ "$status" != "connected" ]]; then
        exit 0
      fi

      # Read first 256 bytes directly (sysfs bin_attribute st_size can be 0; -v avoids '*' suppression)
      edid_hex="$(od -An -tx1 -v -N 256 "$connector_dir/edid" 2>/dev/null | tr -d ' \n' || true)"
      if (( ''${#edid_hex} < 512 )); then
        exit 0
      fi

      # Match Dell P2723D strictly: Manufacturer DEL (bytes 8..9 = 10 ac) + Product 0xd140 (bytes 10..11 = 40 d1)
      if [[ "''${edid_hex:16:8}" != "10ac40d1" ]]; then
        exit 0
      fi

      # Already running RGB-only EDID (CTA-861 byte 131 / 0x83 == 0x81) — exit silently to prevent loops
      if [[ "''${edid_hex:262:2}" == "81" ]]; then
        exit 0
      fi

      # Short cooldown guard against rapid re-trigger loops
      now="$(date +%s)"
      if [[ -f "$cooldown_file" ]]; then
        last_apply="$(cat "$cooldown_file" 2>/dev/null || echo 0)"
        if [[ "$last_apply" =~ ^[0-9]+$ ]] && (( now - last_apply < 5 )); then
          exit 0
        fi
      fi

      printf '%s\n' "$now" >"$cooldown_file"
      cat "${./edid/dell-p2723d-rgb.bin}" >"$edid_override"

      if [[ -w "$trigger_hotplug" ]]; then
        printf '1\n' >"$trigger_hotplug"
      elif [[ -w "$connector_dir/status" ]]; then
        printf 'detect\n' >"$connector_dir/status"
      fi

      echo "Applied Dell P2723D RGB-only EDID override on HDMI-A-1 (PCI ''${pci_addr:-unknown}, previous byte 0x83=0x''${edid_hex:262:2})"
    '';
  };
in
{
  # Use the unstable NetBird module alongside pkgs-unstable.netbird/netbird-ui (0.82.x desktop entry format)
  disabledModules = [ "services/networking/netbird.nix" ];

  imports = [
    ./hardware-configuration.nix
    ./desktop.nix
    ./gaming.nix
    "${nixpkgs-unstable}/nixos/modules/services/networking/netbird.nix"
  ];

  # Allows `nix flake check` to evaluate this host cleanly before hardware-configuration.nix is generated
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Keep desktop & gaming smooth during background Nix builds and deduplicate store writes
  nix = {
    settings.auto-optimise-store = true;
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
  };

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

    # Prevent AMD Vega 8 (Picasso) split green/black display flash on DPMS-off & suspend
    kernelParams = [
      "amdgpu.sg_display=0"
    ];

    # Preload TCP BBR module before systemd-sysctl activates BBR congestion control
    kernelModules = [ "tcp_bbr" ];

    # Clean disk-backed /tmp on boot (keep useTmpfs = false on 15 GiB RAM)
    tmp.cleanOnBoot = true;

    # Tune VM paging for ZRAM-only swap and enable TCP BBR for Wi-Fi/5G responsiveness
    kernel.sysctl = {
      "vm.swappiness" = 180;
      "vm.page-cluster" = 0;
      "vm.watermark_boost_factor" = 0;
      "vm.watermark_scale_factor" = 125;
      "net.core.default_qdisc" = "fq";
      "net.ipv4.tcp_congestion_control" = "bbr";
    };
  };

  # Placeholder label-based mounts using mkDefault so `nixos-generate-config` UUID entries
  # in hardware-configuration.nix override them without conflicts during installation.
  fileSystems = {
    "/" = {
      device = lib.mkDefault "/dev/disk/by-label/NIXROOT";
      fsType = lib.mkDefault "ext4";
      options = [ "noatime" ];
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
        "x-systemd.idle-timeout=5min"
        "x-systemd.device-timeout=5s"
        "x-systemd.mount-timeout=5s"
        "x-systemd.before=remote-fs.target"
        "x-systemd.after=netbird-wt0.service"
        "nofail"
        "_netdev"
        "soft"
        "echo_interval=10"
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
        "x-systemd.idle-timeout=5min"
        "x-systemd.device-timeout=5s"
        "x-systemd.mount-timeout=5s"
        "x-systemd.before=remote-fs.target"
        "x-systemd.after=netbird-wt0.service"
        "nofail"
        "_netdev"
        "soft"
        "echo_interval=10"
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
        "x-systemd.idle-timeout=5min"
        "x-systemd.device-timeout=5s"
        "x-systemd.mount-timeout=5s"
        "x-systemd.before=remote-fs.target"
        "x-systemd.after=netbird-wt0.service"
        "nofail"
        "_netdev"
        "soft"
        "echo_interval=10"
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

  systemd = {
    tmpfiles.rules = [
      "d /var/lib/secrets 0700 root root -"
    ];

    services = {
      # Stop user apps before remote-fs.target unmounts CIFS shares during shutdown
      "user@".after = [ "remote-fs.target" ];

      # Dynamically apply Dell P2723D RGB-only EDID on HDMI-A-1 at boot, hotplug, and post-resume
      hdmi-edid-override = {
        description = "Apply Dell P2723D RGB-only EDID override on HDMI-A-1";
        after = [
          "multi-user.target"
          "sys-kernel-debug.mount"
          "suspend.target"
          "hibernate.target"
          "hybrid-sleep.target"
          "suspend-then-hibernate.target"
        ];
        wantedBy = [
          "graphical.target"
          "suspend.target"
          "hibernate.target"
          "hybrid-sleep.target"
          "suspend-then-hibernate.target"
        ];
        unitConfig = {
          # Allow rapid hotplug uevents without hitting systemd start-rate limits (loop protection is in the script)
          StartLimitIntervalSec = 0;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe hdmiEdidOverride;
        };
      };

      # Reset any active HDMI-A-1 EDID override before suspend so swapped displays probe native EDID on wake
      hdmi-edid-override-reset = {
        description = "Reset HDMI-A-1 EDID override before suspend";
        before = [ "sleep.target" ];
        wantedBy = [ "sleep.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe hdmiEdidOverride} --reset";
        };
      };
    };

    # Detach busy CIFS mounts lazily on shutdown so they never stay stacked over autofs after network teardown
    units =
      let
        lazyUnmountDropin = {
          overrideStrategy = "asDropin";
          text = ''
            [Mount]
            LazyUnmount=yes
          '';
        };
      in
      {
        "mnt-roms.mount" = lazyUnmountDropin;
        "mnt-nas\\x2dgames.mount" = lazyUnmountDropin;
        "mnt-nas\\x2ddata.mount" = lazyUnmountDropin;
      };

    # Protect KDE Plasma user sessions and system slices from hard RAM-exhaustion freezes
    oomd = {
      enableRootSlice = true;
      enableSystemSlice = true;
      enableUserSlices = true;
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
    # Local caching DNS stub resolver (integrates natively with NetworkManager and NetBird split-DNS via polkit)
    resolved = {
      enable = true;
      settings.Resolve = {
        FallbackDNS = [ ];
        LLMNR = "false";
      };
    };
    switcherooControl.enable = true;
    power-profiles-daemon.enable = true;

    # Latency-criticality aware sched_ext scheduler (binary-cached; requires CONFIG_SCHED_CLASS_EXT=y)
    scx = {
      enable = true;
      package = pkgs.scx.rustscheds;
      scheduler = "scx_lavd";
    };

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

    # NetBird WireGuard mesh VPN client (pinned to unstable to match homelab & 0.80.x+ self-hosted stack)
    netbird = {
      package = pkgs-unstable.netbird;
      ui = {
        enable = true;
        package = pkgs-unstable.netbird-ui;
      };
      useRoutingFeatures = "client";
      clients.wt0 = {
        port = 51820;
        interface = "wt0";
        openFirewall = false;
        autoStart = true;
        ui.enable = true;
      };
    };

    udev = {
      # Hidraw/uaccess rules for 8BitDo Pro 3 (Bluetooth and USB/2.4GHz dongle) and other gamepads
      packages = [ pkgs.game-devices-udev-rules ];
      # Dynamically apply Dell P2723D RGB-only EDID on HDMI hotplug while leaving other displays native
      extraRules = ''
        SUBSYSTEM=="drm", ACTION=="change", ENV{HOTPLUG}=="1", RUN+="${pkgs.systemd}/bin/systemctl start --no-block hdmi-edid-override.service"
      '';
    };
  };

  # Declarative autostart for wrapped NetBird UI (prevents unwrapped store-path autostart entries)
  environment.etc."xdg/autostart/netbird-wt0.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=NetBird @ netbird-wt0
    Comment=NetBird desktop client
    Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 /run/current-system/sw/bin/netbird-ui-wt0
    TryExec=/run/current-system/sw/bin/netbird-ui-wt0
    Icon=${pkgs-unstable.netbird-ui}/share/icons/hicolor/256x256/apps/netbird.png
    Terminal=false
    Categories=Utility;
    X-GNOME-Autostart-enabled=true
  '';

  security.rtkit.enable = true;

  # NixOS CLI helper, unpatched binary/AppImage compatibility (gaming stack lives in ./gaming.nix)
  programs = {
    nh = {
      enable = true;
      flake = "/etc/nixos";
      # clean.enable intentionally omitted: modules/common.nix manages nix.gc.automatic
    };

    nix-ld.enable = true;

    appimage = {
      enable = true;
      binfmt = true;
    };
  };

  # Run Electron & Chromium apps natively on Wayland (VS Code, Discord, Element, Obsidian, Signal, Spotify, Chromium)
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

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
        "netbird-wt0"
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

    haruna
    jdk11
    # jetbrains-toolbox # upstream 404 in 26.05
    metadata-cleaner
    obsidian
    onlyoffice-desktopeditors
    picard
    spotify
    strawberry

    amdgpu_top
    android-tools
    cifs-utils
    kdePackages.gwenview
    kdePackages.kate
    libva-utils
    ntfs3g
    nvtopPackages.amd
    peazip
    smartmontools
    testdisk
  ];

  system.autoUpgrade = {
    enable = true;
    flake = "github:kampisellis/nixos-config#laptop";
    dates = "Tue *-*-* 12:00:00";
    operation = "boot";
    allowReboot = false;
    persistent = true;
    randomizedDelaySec = "30min";
  };

  systemd.services.nixos-upgrade.unitConfig.ConditionACPower = true;

  system.stateVersion = "26.05";
}
