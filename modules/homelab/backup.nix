{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;
in
{
  config = lib.mkIf cfg.enable {
    services = {
      postgresqlBackup = {
        enable = true;
        location = "/var/lib/backup/postgresql";
        databases = [ "immich" ];
        startAt = "*-*-* 02:15:00";
      };

      sanoid = {
        enable = true;
        datasets = {
          "tank/var-lib" = {
            hourly = 24;
            daily = 30;
            monthly = 3;
            autosnap = true;
            autoprune = true;
          };
          "tank/data" = {
            # Explicit (sanoid's default template would otherwise apply 48 silently);
            # mirrored by backup-snapshot-prune on backup/personal-backup.
            hourly = 48;
            daily = 30;
            monthly = 6;
            autosnap = true;
            autoprune = true;
          };
        };
      };

      syncoid = {
        enable = true;
        # Run once daily right after the 03:00 sanoid snapshot (which includes the 02:15 DB dump)
        # so the backup HDD spins up only once per day.
        interval = "*-*-* 03:05:00";
        commonArgs = [ "--no-sync-snap" ];
        service.serviceConfig.Type = "oneshot";
        commands = {
          "state-backup" = {
            source = "tank/var-lib";
            target = "backup/var-lib";
            service.after = [
              "sanoid.service"
              "postgresqlBackup-immich.service"
              "backup-vaultwarden.service"
            ];
          };
          "data-backup" = {
            source = "tank/data";
            target = "backup/personal-backup";
            service.after = [ "syncoid-state-backup.service" ];
          };
        };
      };

      restic.backups.gdrive-system = {
        initialize = true;
        repository = "rclone:gdrive:homelab-backups/system-encrypted";
        passwordFile = "${cfg.secretsDir}/restic.pass";
        rcloneConfigFile = "${cfg.secretsDir}/rclone-backup.conf";
        paths = [
          "/var/lib/backup/postgresql"
          "/var/lib/backup/vaultwarden"
          "/var/lib/radicale"
          "/var/lib/couchdb"
          "/var/lib/private/technitium-dns-server"
          # Static uid/gid allocations so restored file ownership matches after a full rebuild
          "/var/lib/nixos"
          cfg.secretsDir
        ];
        timerConfig = {
          OnCalendar = "*-*-* 03:45:00";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };

      restic.backups.gdrive-other-backups = {
        initialize = true;
        repository = "rclone:gdrive:homelab-backups/other-backups-encrypted";
        passwordFile = "${cfg.secretsDir}/restic.pass";
        rcloneConfigFile = "${cfg.secretsDir}/rclone-backup.conf";
        paths = [
          "/mnt/nas-data/Giannis/Library/Backups"
          "/mnt/nas-data/Games/saves"
        ];
        timerConfig = {
          OnCalendar = "*-*-* 03:50:00";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };
    };

    # Catch up on missed nightly jobs at the next boot (e.g. after a UPS shutdown)
    systemd.timers =
      lib.genAttrs
        [
          "postgresqlBackup-immich"
          "sanoid"
          "syncoid-state-backup"
          "syncoid-data-backup"
          "backup-snapshot-prune"
          "rclone-gdrive-backup"
          "restic-check-gdrive"
        ]
        (_: {
          timerConfig.Persistent = true;
        });

    systemd.services = {
      # Ensure post-outage catch-up snapshots capture fresh DB dumps before syncoid replicates them
      sanoid.after = [
        "postgresqlBackup-immich.service"
        "backup-vaultwarden.service"
      ];

      restic-backups-gdrive-system = {
        after = [
          "network-online.target"
          "postgresqlBackup-immich.service"
          "backup-vaultwarden.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig.ExecStartPre = lib.mkBefore [
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/restic.pass"
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
        ];
      };

      restic-backups-gdrive-other-backups = {
        after = [
          "network-online.target"
          "restic-backups-gdrive-system.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig.RequiresMountsFor = "/mnt/nas-data";
        serviceConfig.ExecStartPre = lib.mkBefore [
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/restic.pass"
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
        ];
      };

      # Prune replicated snapshots on backup in the same daily HDD wake window
      backup-snapshot-prune = {
        description = "Prune old replicated snapshots on backup pool";
        startAt = "*-*-* 03:20:00";
        after = [
          "syncoid-state-backup.service"
          "syncoid-data-backup.service"
        ];
        path = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.zfs
        ];
        script = ''
          set -euo pipefail

          prune_class() {
            local ds="$1"
            local class="$2"
            local keep="$3"
            local snaps

            snaps="$(zfs list -t snapshot -H -o name -S creation "$ds")"
            printf '%s\n' "$snaps" \
              | { grep -E "@autosnap_.*_''${class}$" || true; } \
              | tail -n +"$((keep + 1))" \
              | xargs -r -n1 zfs destroy
          }

          prune_class backup/var-lib hourly 24
          prune_class backup/var-lib daily 30
          prune_class backup/var-lib monthly 3

          prune_class backup/personal-backup hourly 48
          prune_class backup/personal-backup daily 30
          prune_class backup/personal-backup monthly 6
        '';
        serviceConfig.Type = "oneshot";
      };

      # Daily unencrypted sync of Immich media, Documents, and Site to Google Drive
      rclone-gdrive-backup = {
        description = "Sync Immich media, Documents, and Site to Google Drive";
        startAt = "*-*-* 04:00:00";
        after = [
          "network-online.target"
          "restic-backups-gdrive-system.service"
          "restic-backups-gdrive-other-backups.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig.RequiresMountsFor = "/mnt/nas-data";
        path = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.rclone
          pkgs.util-linux
        ];
        script = ''
          set -euo pipefail

          if ! mountpoint -q /mnt/nas-data; then
            echo "ERROR: /mnt/nas-data is not mounted; aborting rclone backup" >&2
            exit 1
          fi

          MEDIA_SRC="/mnt/nas-data/Giannis/Apps/Immich/library/admin"
          DOCS_SRC="/mnt/nas-data/Giannis/Library/Documents"
          SITE_SRC="/mnt/nas-data/Giannis/Apps/Site"

          for src in "$MEDIA_SRC" "$DOCS_SRC" "$SITE_SRC"; do
            if [[ ! -d "$src" ]]; then
              echo "ERROR: backup source directory missing: $src" >&2
              exit 1
            fi
            if [[ -z "$(find "$src" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
              echo "ERROR: backup source directory is empty: $src" >&2
              exit 1
            fi
          done

          TODAY="$(date +%Y-%m-%d)"
          RCLONE_FLAGS=(
            --config=${cfg.secretsDir}/rclone-backup.conf
            --fast-list
            --track-renames
            --transfers=4
            --checkers=8
            --stats=30s
            --stats-one-line
            --log-level=INFO
          )

          # Per-target --max-delete caps calibrated to library sizes (~16.6k media, ~344 documents, ~242 site);
          # run independently so a --max-delete abort on one target does not skip syncing the others.
          failed=0

          rclone sync "''${RCLONE_FLAGS[@]}" \
            --max-delete=2000 \
            --backup-dir "gdrive:homelab-backups/_deleted/$TODAY/media" \
            "$MEDIA_SRC" \
            gdrive:homelab-backups/media || failed=1

          rclone sync "''${RCLONE_FLAGS[@]}" \
            --max-delete=120 \
            --backup-dir "gdrive:homelab-backups/_deleted/$TODAY/documents" \
            "$DOCS_SRC" \
            gdrive:homelab-backups/documents || failed=1

          rclone sync "''${RCLONE_FLAGS[@]}" \
            --max-delete=100 \
            --backup-dir "gdrive:homelab-backups/_deleted/$TODAY/site" \
            "$SITE_SRC" \
            gdrive:homelab-backups/site || failed=1

          # Expire dated trash folders older than 30 days (by folder name, since moved
          # files keep their original modification times); rclone exit code 3 = directory not found.
          CUTOFF="$(date -d '30 days ago' +%Y-%m-%d)"
          lsf_rc=0
          lsf_out="$(rclone lsf --config=${cfg.secretsDir}/rclone-backup.conf --dirs-only gdrive:homelab-backups/_deleted)" || lsf_rc=$?
          if [ "$lsf_rc" -eq 0 ]; then
            while IFS= read -r dir; do
              dir="''${dir%/}"
              if [[ "$dir" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$dir" < "$CUTOFF" ]]; then
                echo "Purging expired trash folder: $dir"
                rclone purge --config=${cfg.secretsDir}/rclone-backup.conf \
                  "gdrive:homelab-backups/_deleted/$dir" || failed=1
              fi
            done <<< "$lsf_out"
          elif [ "$lsf_rc" -ne 3 ]; then
            echo "ERROR: failed to list gdrive:homelab-backups/_deleted (rc=$lsf_rc)" >&2
            failed=1
          fi

          if [ "$failed" -ne 0 ]; then
            exit 1
          fi

          # Optional external dead-man's-switch heartbeat (safe no-op until configured);
          # also confirms local ntfy-sh is healthy before pinging so an alert outage is detected externally.
          if [ -s ${cfg.secretsDir}/healthcheck-url ]; then
            hc_url="$(tr -d '[:space:]' < ${cfg.secretsDir}/healthcheck-url)"
            if [ -n "$hc_url" ]; then
              if ${pkgs.curl}/bin/curl -fsS --max-time 5 "http://127.0.0.1:${toString cfg.ports.ntfy}/v1/health" >/dev/null; then
                ${pkgs.curl}/bin/curl -fsS --max-time 10 --retry 3 --retry-delay 2 "$hc_url" >/dev/null || true
              else
                echo "WARNING: local ntfy-sh health check failed; skipping external heartbeat" >&2
              fi
            fi
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          ExecStartPre = lib.mkBefore [
            "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
          ];
        };
      };

      # Weekly Restic repository integrity check (5% data read-back) on Google Drive
      restic-check-gdrive = {
        description = "Weekly Restic integrity check for Google Drive backups";
        startAt = "Sun *-*-* 04:30:00";
        after = [
          "network-online.target"
          "restic-backups-gdrive-system.service"
          "restic-backups-gdrive-other-backups.service"
          "rclone-gdrive-backup.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig.RequiresMountsFor = cfg.secretsDir;
        script = ''
          set -euo pipefail
          /run/current-system/sw/bin/restic-gdrive-system check --read-data-subset=5%
          /run/current-system/sw/bin/restic-gdrive-other-backups check --read-data-subset=5%
        '';
        serviceConfig = {
          Type = "oneshot";
          ExecStartPre = lib.mkBefore [
            "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/restic.pass"
            "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
          ];
        };
      };
    };
  };
}
