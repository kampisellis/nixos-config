{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;

  motdScript = pkgs.writeShellScriptBin "homelab-motd" ''
    set -u

    HOST="$(${pkgs.coreutils}/bin/uname -n)"
    KERNEL="$(${pkgs.coreutils}/bin/uname -r)"
    UPTIME="$(${pkgs.procps}/bin/uptime -p 2>/dev/null || echo 'unknown')"
    LOAD="$(${pkgs.coreutils}/bin/cut -d' ' -f1-3 /proc/loadavg)"
    FAILED_COUNT="$(${pkgs.systemd}/bin/systemctl --failed --no-legend --plain 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)"

    printf '\n=== %s (NixOS | kernel %s) ===\n' "$HOST" "$KERNEL"
    printf 'Uptime: %s | Load: %s | Failed units: %s\n' "$UPTIME" "$LOAD" "$FAILED_COUNT"

    if [ "$FAILED_COUNT" -gt 0 ]; then
      printf '\nFailed systemd units:\n'
      ${pkgs.systemd}/bin/systemctl --failed --no-legend --plain 2>/dev/null \
        | ${pkgs.gnused}/bin/sed 's/^/  - /'
    fi

    printf '\nZFS pools:\n'
    if ! ${pkgs.zfs}/bin/zpool list -H -o name,size,alloc,free,cap,health 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '{ printf "  %-8s size=%-6s alloc=%-6s free=%-6s cap=%-4s health=%s\n", $1, $2, $3, $4, $5, $6 }'; then
      printf '  (unavailable without privileges; run: sudo zpool status -x)\n'
    fi

    printf '\nStorage mounts:\n'
    ${pkgs.coreutils}/bin/df -h --output=target,size,used,avail,pcent / /boot /var/lib /mnt/nas-data 2>/dev/null \
      | ${pkgs.gnused}/bin/sed 's/^/  /'
    printf '\n'
  '';
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ motdScript ];

    programs.bash.interactiveShellInit = ''
      if [ -n "''${SSH_CONNECTION:-}" ] && [ -t 1 ]; then
        ${motdScript}/bin/homelab-motd || true
      fi
    '';
  };
}
