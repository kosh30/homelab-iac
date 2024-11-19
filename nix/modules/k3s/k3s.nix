{
  pkgs,
  lib,
  config,
  ...
}:

{
  options = {
    k3s = with lib; {
      master = mkOption {
        type = types.bool;
        description = "Whether or not this is a master node";
      };
      clusterInit = mkOption {
        type = types.bool;
        description = "Whether or not to initialize the HA cluster";
        default = false;
      };
      singleNode = mkOption {
        type = types.bool;
        description = "Whether or not this is a single node cluster";
        default = false;
      };
    };
  };
  config = {
    environment.systemPackages =
      with pkgs;
      [
        ceph-client # ceph kernel modules for ceph-csi
      ]
      ++ (lib.optionals (config.k3s.master) [
        etcd # for etcdctl
      ]);

    programs.bash.shellAliases =
      {
        k = "kubectl";
        dropcaches = "sync; echo 3 > /proc/sys/vm/drop_caches";
      }
      // (lib.optionalAttrs (config.k3s.master) {
        ketcdctl = "etcdctl --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt --key=/var/lib/rancher/k3s/server/tls/etcd/client.key";
      });

    boot.kernelModules = [
      # ceph for ceph-csi
      "ceph"
      "rbd"

      # IPVS for kube-vip
      "ip_vs"
      "ip_vs_rr"

      # Wireguard for VPN
      "tun"
      "wireguard"
    ];

    networking.firewall.allowedTCPPorts =
      [
        6443 # k3s: required so that pods can reach the API server (running on port 6443 by default)
      ]
      ++ (lib.optionals (!config.k3s.singleNode) [
        2379 # k3s, etcd clients: required if using a "High Availability Embedded etcd" configuration
        2380 # k3s, etcd peers: required if using a "High Availability Embedded etcd" configuration
        5001 # k3s: embedded Spigel registry mirror
        10250 # k3s: metrics server
      ]);
    networking.firewall.allowedUDPPorts = lib.mkIf (!config.k3s.singleNode) [
      8472 # k3s, flannel: required if using multi-node for inter-node networking
    ];

    sops.secrets.k3s-token = { };

    services.k3s = {
      enable = true;
      role = if config.k3s.master then "server" else "agent";
      tokenFile = lib.mkIf (!config.k3s.singleNode) config.sops.secrets.k3s-token.path;
      serverAddr = lib.mkIf (
        !config.k3s.singleNode && !config.k3s.clusterInit
      ) "https://k3s.wuhoo.xyz:6443";
      clusterInit = config.k3s.clusterInit;

      extraFlags = toString (
        [ ]
        ++ (
          if config.k3s.master then
            if config.k3s.singleNode then
              [
                "--tls-san ${config.networking.hostName}.wuhoo.xyz"
                "--disable traefik"
                "--disable local-storage"
                "--disable-cloud-controller"
                "--kubelet-arg node-status-update-frequency=5s"
                "--kube-controller-manager-arg node-monitor-period=5s"
                "--kube-controller-manager-arg node-monitor-grace-period=20s"
              ]
            else
              [
                "--tls-san k3s.wuhoo.xyz"
                "--disable traefik"
                "--disable servicelb"
                "--disable local-storage"
                "--disable-cloud-controller"
                "--kubelet-arg node-status-update-frequency=5s"
                "--kube-controller-manager-arg node-monitor-period=5s"
                "--kube-controller-manager-arg node-monitor-grace-period=20s"
                "--kube-controller-manager-arg bind-address=0.0.0.0"
                "--kube-proxy-arg metrics-bind-address=0.0.0.0"
                "--kube-scheduler-arg bind-address=0.0.0.0"
                "--etcd-expose-metrics"
                "--embedded-registry"
              ]
          else
            [ ]
        )
      );

      configPath = lib.mkIf (
        config.k3s.master && !config.k3s.singleNode
      ) config.sops.templates.k3s-config.path;
    };

    sops.secrets.aws-access-key-id = lib.mkIf (config.k3s.master && !config.k3s.singleNode) { };
    sops.secrets.aws-secret-access-key = lib.mkIf (config.k3s.master && !config.k3s.singleNode) { };
    sops.templates.k3s-config = lib.mkIf (config.k3s.master && !config.k3s.singleNode) {
      content = ''
        etcd-s3: true
        etcd-s3-endpoint: s3.wuhoo.xyz
        etcd-s3-bucket: backup
        etcd-s3-folder: etcd
        etcd-s3-access-key: ${config.sops.placeholder.aws-access-key-id}
        etcd-s3-secret-key: ${config.sops.placeholder.aws-secret-access-key}
      '';
    };

    environment.etc = {
      # Enable both embedded Spigel registry and external registry mirrors
      "rancher/k3s/registries.yaml" = {
        source = ./manifests/registries.yaml;
        mode = "0644";
      };
    };
  };
}