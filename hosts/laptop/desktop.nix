{ pkgs, ... }:

let
  # Minimal dark Breeze SDDM theme override (solid #1b1e20 background, Inter font; zero local builds)
  sddmBreezeMinimal = pkgs.runCommandLocal "sddm-breeze-minimal" { } ''
    mkdir -p "$out/share/sddm/themes/breeze-minimal"
    for f in ${pkgs.kdePackages.plasma-desktop}/share/sddm/themes/breeze/*; do
      ln -s "$f" "$out/share/sddm/themes/breeze-minimal/"
    done
    cat > "$out/share/sddm/themes/breeze-minimal/theme.conf.user" <<'EOF'
    [General]
    type=color
    color=#1b1e20
    background=
    showlogo=hidden
    showClock=true
    font=Inter
    fontSize=10
    EOF
  '';
in
{
  # Typography: Inter (UI) + JetBrainsMono Nerd Font (mono) with existing Noto Sans/Emoji fallbacks for Greek & emoji
  fonts = {
    packages = with pkgs; [
      inter
      nerd-fonts.jetbrains-mono
    ];

    fontconfig = {
      antialias = true;
      hinting = {
        enable = true;
        style = "slight";
      };
      subpixel.rgba = "rgb";
      defaultFonts = {
        sansSerif = [
          "Inter"
          "Noto Sans"
        ];
        monospace = [ "JetBrainsMono Nerd Font" ];
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };

  # Native Breeze Dark icon, cursor & minimal dark SDDM theme companions (breeze-gtk and kde-gtk-config are already included by Plasma 6)
  environment.systemPackages = with pkgs; [
    bibata-cursors
    papirus-icon-theme
    sddmBreezeMinimal
  ];

  # Ultra-minimal, fast single-line CLI prompt (auto-hooks into bash; noisy language/cloud modules omitted)
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$username$hostname$directory$git_branch$git_status$nix_shell$cmd_duration$character";

      directory = {
        truncation_length = 3;
        truncate_to_repo = false;
        style = "bold cyan";
      };

      git_branch = {
        symbol = " ";
        style = "purple";
        format = "[$symbol$branch]($style) ";
      };

      git_status = {
        style = "red";
        format = "([$all_status$ahead_behind]($style) )";
      };

      nix_shell = {
        symbol = "❄ ";
        style = "blue";
        format = "[$symbol$name]($style) ";
      };

      cmd_duration = {
        min_time = 2000;
        style = "dimmed yellow";
        format = "[$duration]($style) ";
      };

      character = {
        success_symbol = "[❯](bold blue)";
        error_symbol = "[❯](bold red)";
      };
    };
  };

  # Seamless silent boot into SDDM Wayland (merges with amdgpu.sg_display=0 in default.nix)
  boot = {
    plymouth.enable = true;
    consoleLogLevel = 3;
    initrd.verbose = false;
    kernelParams = [
      "quiet"
      "splash"
      "udev.log_level=3"
    ];
  };

  # Cohesive minimal dark SDDM Wayland login theme & cursor matching Plasma 6 Breeze Dark
  services.displayManager.sddm = {
    theme = "breeze-minimal";
    settings.Theme = {
      CursorTheme = "Bibata-Modern-Classic";
      CursorSize = 24;
      Font = "Inter,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1";
    };
  };
}
