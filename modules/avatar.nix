# zoe's profile picture = her GitHub avatar (https://github.com/zoeleu.png),
# fetched at boot and daily, so changing it on GitHub updates the login
# screen, lock screen and Plasma. Stored where AccountsService (which they
# all read) looks for it. If GitHub is unreachable, the last one stays.
{ pkgs, ... }:

{
  systemd.services.zoe-avatar = {
    description = "Set zoe's profile picture to her GitHub avatar";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [ curl coreutils file ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -eu
      icons=/var/lib/AccountsService/icons
      users=/var/lib/AccountsService/users
      mkdir -p "$icons" "$users"
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      curl -fsSL --max-time 30 "https://github.com/zoeleu.png?size=256" -o "$tmp"
      file -b --mime-type "$tmp" | grep -q '^image/' || { echo "not an image"; exit 1; }
      install -m 644 "$tmp" "$icons/zoe"
      if [ -f "$users/zoe" ] && grep -q '^Icon=' "$users/zoe"; then
        sed -i "s|^Icon=.*|Icon=$icons/zoe|" "$users/zoe"
      elif [ -f "$users/zoe" ]; then
        printf 'Icon=%s\n' "$icons/zoe" >> "$users/zoe"
      else
        printf '[User]\nIcon=%s\n' "$icons/zoe" > "$users/zoe"
      fi
    '';
  };
  systemd.timers.zoe-avatar = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1d";
      Persistent = true;
    };
  };
}
