{ config, pkgs, ... }:

{
  # Κλείδωμα της Realtek RTL8125 2.5GbE (MAC d8:5e:d3:9c:11:15) στο όνομα "nic0"
  systemd.network.links."10-nic0" = {
    matchConfig.MACAddress = "d8:5e:d3:9c:11:15";
    linkConfig.Name = "nic0";
  };

  services.resolved.enable = false;

  networking = {
    hostName = "homelab";
    hostId = "8425e349";
    useDHCP = false;

    interfaces.nic0.ipv4.addresses = [
      { address = "10.10.10.5";   prefixLength = 24; } # Κύρια IP
      { address = "10.10.10.101"; prefixLength = 24; } # Alias για Technitium DNS
      { address = "10.10.10.105"; prefixLength = 24; } # Alias για Caddy
      { address = "10.10.10.109"; prefixLength = 24; } # Alias για VPS NetBird -> :8085
    ];

    defaultGateway = "10.10.10.1";
    nameservers = [ "127.0.0.1" "1.1.1.1" ];

    firewall = {
      enable = true;
      trustedInterfaces = [ "wt0" ];
      allowedTCPPorts = [ 22 53 80 443 5380 8053 8085 ];
      allowedUDPPorts = [ 53 443 51820 ];
    };
  };

  services.technitium-dns-server = {
    enable = true;
    openFirewall = true;
  };

  services.netbird = {
    useRoutingFeatures = "both";
    clients.wt0 = {
      port = 51820;
      interface = "wt0";
      openFirewall = true;
      autoStart = true;
    };
  };
}
