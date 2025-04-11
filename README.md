<div align="center">

![alt text](logo.png "Title")

<img src="https://uptime-kuma.kthxbye.cyou/api/badge/43/uptime?labelPrefix=Node+" alt="Node Uptime">
<img src="https://uptime-kuma.kthxbye.cyou/api/badge/90/uptime?labelPrefix=Cluster+" alt="Cluster Uptime">
<img src="https://uptime-kuma.kthxbye.cyou/api/badge/63/uptime?labelPrefix=Service+" alt="Service Uptime">

<h3>Bootstrap and GitOps sources to get my baremetal homelab set up consistently.</h3>

</div>

# 🏡 Homelab-as-Code (HaC™)

This repository was born out of the need to better manage an ever-growing homelab environment.
After starting with a simple single-node Docker Compose setup, the increasing number of services began to make maintenance and updates more challenging.

As the complexity grew, it became clear that a more structured, Infrastructure-as-Code approach was needed to:
- keep configurations versioned and thus better documented
- make deployments more consistently repeatable and reliable
- simplify the process of adding new services without losing track of the overall state
- enable easier backup and disaster recovery that is centrally managed
- provide better scalability and resilience beyond a single node

I decided to take this opportunity to properly learn Kubernetes hands-on, embracing the complexity and "feeling the pain" that comes with it rather than _just_ having the theoretical knowledge.
This repo serves as both documentation of my setup as well as a real-world learning experience in managing infrastructure that I rely upon as code.

PS: This setup is mature enough to be girlfriend-approved. 😉

## 🔰 Overview

At the highest possible level, this repo and HaC workflow consists of three parts:
- [cloud-init](cloud-init) contains the stage 1 bootstrapping for the cluster nodes.
  This includes only the very basic OS-level configuration required for the others stages of this workflow.
  The contained shell script creates all files required to install the OS via [network boot](https://ubuntu.com/server/docs/how-to-netboot-the-server-installer-on-amd64) and without user interaction.
  _Triggering_ the network-boot installation is out-of-scope for the moment.
  After completion of the cloud-init [autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/intro-to-autoinstall.html), all nodes reboot and are ready to accept SSH connections.
- [ansible](ansible) contains the stage 2 system configuration for the cluster nodes.
  This includes a range of tasks including power management, networking setup, and most importantly bootstrapping the kubernetes cluster using [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/).
  The contained ansible playbook and roles perform the required tasks on the nodes via an SSH and a dedicated ansible user created in the previous step.
  After completion of this stage, the kubernetes cluster is set up with [HA](https://kube-vip.io/) control planes, joined worker nodes, dual-stack [CNI](https://www.tigera.io/tigera-products/calico/), almost working [OIDC authn](https://dexidp.io/), and last but not least a bootstrapped [GitOps](https://fluxcd.io/) setup that is ready to start reconciling.
- [flux](flux) contains the final stage 3 GitOps cluster configuration.
  This includes everything running _inside_ kubernetes in the cluster and ranges from basic system infrastructure like [load balancer](https://metallb.io/), [ingress](https://kubernetes.github.io/ingress-nginx/), and [CSI](https://longhorn.io/) to more user-style applications such as [password manager](https://bitwarden.com/) and [file management](https://nextcloud.com/) apps.
  The contained flux kustomizations are automatically installed and/or reconciled on the cluster without* user interaction.
  This process is staggered since there is an inherent dependency between some of the components.
  After completion of this stage, the cluster is fully set up and ready for use.

## 📐 Tech Stack

| Component                                                            | Purpose                                | Notes                                                                              |
| -------------------------------------------------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------- |
| [Ubuntu Server 24.04](https://ubuntu.com/server)                     | Base Operating System                  |                                                                                    |
| [cloud-init](https://cloud-init.io/)                                 | Headless OS Installation               | see [cloud-init/README.md](cloud-init/README.md)                                   |
| [Ansible](https://ansible.com/)                                      | OS Configuration                       |                                                                                    |
| [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) | k8s _Distribution_ / Install Mechanism | stacked HA controlplanes                                                           |
| [containerd](https://containerd.io/)                                 | OCI Runtime                            |                                                                                    |
| [Calico](https://www.tigera.io/tigera-products/calico/)              | CNI                                    | dual-stack nodes and services                                                      |
| [kube-vip](https://kube-vip.io/)                                     | Virtual IP for controlplane Nodes      | used in L2/ARP mode                                                                |
| [Flux2](https://fluxcd.io)                                           | GitOps Automation inside the Cluster   |                                                                                    |
| [SOPS](https://getsops.io/)                                          | Secrets Management                     | [age](https://age-encryption.org/) rather than pgp, but not any more user-friendly |

## 📱 Applications

### 🤖 System-Level

<table>
    <tr>
        <th></th>
        <th>Name</th>
        <th>Purpose</th>
        <th>Notes</th>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/metallb/metallb/refs/heads/main/website/static/images/logo/metallb-blue.svg"></td>
        <td><a href="https://metallb.io/">metallb</a></td>
        <td>Cloud-Native Service LoadBalancer</td>
        <td>used in L2/ARP mode, so only VIP rather than true LB</td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/heads/master/docs/img/external-dns.png"></td>
        <td><a href="https://kubernetes-sigs.github.io/external-dns/">external-dns</a></td>
        <td>DNS Management Automation</td>
        <td>split-horizon realized using <a href="https://github.com/jobs62/opnsense_unbound_external-dns_webhook">opnsense webhook</a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/cert-manager/cert-manager/refs/heads/master/logo/logo.svg"></td>
        <td><a href="https://cert-manager.io/">cert-manager</a></td>
        <td>Automated Certificate Management</td>
        <td>Let's Encrypt via ACME DNS</td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/nginx/nginx.org/refs/heads/main/img/ingress_logo.svg"></td>
        <td><a href="https://kubernetes.github.io/ingress-nginx/">ingress-nginx</a></td>
        <td>Ingress Controller</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/kyverno/kyverno/refs/heads/main/img/logo.png"></td>
        <td><a href="https://kubernetes.github.io/ingress-nginx/">Kyverno</a></td>
        <td>Policy Engine</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/spegel-org/website/refs/heads/main/static/favicon.svg"></td>
        <td><a href="https://spegel.dev/">Spegel</a></td>
        <td>Cluster-Internal P2P Container Image Distribution</td>
        <td><a href="https://spegel.dev/docs/guides/updating-latest-tag/">basically mandates</a> the use of digests or good pinning</td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/longhorn/website/refs/heads/master/static/img/logos/longhorn-icon-color.png"></td>
        <td><a href="https://longhorn.io/">longhorn</a></td>
        <td>Cloud-Native Distributed Block Storage CSI</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://cdn.jsdelivr.net/gh/selfhst/icons/svg/truenas-core.svg"></td>
        <td><a href="https://github.com/democratic-csi/democratic-csi">democratic-csi</a></td>
        <td>CSI for Common External Storage Systems</td>
        <td>using the freenas-nfs implementation</td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/renovatebot/renovate/refs/heads/main/docs/usage/assets/images/logo.png"></td>
        <td><a href="https://www.mend.io/renovate/">Renovate Bot</a></td>
        <td>Dependency Update Automation</td>
        <td>used for multiple repos, not just this one</td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/k8up-io/k8up/refs/heads/master/docs/modules/ROOT/assets/images/k8up-logo-square.svg"></td>
        <td><a href="https://k8up.io/">k8up</a></td>
        <td>Cloud-Native Backup/Restore</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg.github.io/refs/heads/main/assets/images/hero_image.svg"></td>
        <td><a href="https://cloudnative-pg.io/">CloudNativePG</a></td>
        <td>Cloud-Native PostgreSQL Operator</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/grafana/grafana/refs/heads/main/public/img/grafana_icon.svg"></td>
        <td><a href="https://grafana.com/grafana/">Grafana</a></td>
        <td>Montoring and Observability</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/prometheus/prometheus/refs/heads/main/documentation/images/prometheus-logo.svg"></td>
        <td><a href="https://prometheus.io/">Prometheus</a></td>
        <td>Metrics Aggregation and Storage</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/grafana/loki/refs/heads/main/docs/sources/logo.png"></td>
        <td><a href="https://grafana.com/loki/">Loki</a></td>
        <td>Log Aggregation and Storage</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/AnalogJ/scrutiny/refs/heads/master/webapp/frontend/src/assets/images/logo/scrutiny-logo-dark.svg"></td>
        <td><a href="https://github.com/AnalogJ/scrutiny">Scrutiny</a></td>
        <td>Drive Health Monitoring</td>
        <td>via SMART</td>
    </tr>
    <tr>
        <td><img width="32" src="https://openmoji.org/data/color/svg/1F9E6.svg"></td>
        <td><a href="https://github.com/httptoolkit/docker-socks-tunnel/">microsocks</a></td>
        <td>Lightweight SOCKS5 Server</td>
        <td>poor man's monitoring gateway, alternatives: OpenSSH, Isito</td>
    </tr>
    <tr>
        <td><img height="32" width="32" src="https://raw.githubusercontent.com/kubernetes-sigs/descheduler/refs/heads/master/assets/logo/descheduler-stacked-color.png"></td>
        <td><a href="https://sigs.k8s.io/descheduler">descheduler</a></td>
        <td>Pod Eviction for Node Balancing</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/stakater/Reloader/refs/heads/master/assets/web/reloader-round-100px.png"></td>
        <td><a href="https://docs.stakater.com/reloader/">reloader</a></td>
        <td>Hot-Reload for ALL Workloads</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/dexidp/website/refs/heads/main/static/img/logos/dex-glyph-color.svg"></td>
        <td><a href="https://dexidp.io/">Dex</a></td>
        <td>OIDC Provider</td>
        <td>used for api-server authentication</td>
    </tr>
    <tr>
        <td></td>
        <td><a href="https://kubernetes-sigs.github.io/metrics-server/">metrics-server</a></td>
        <td>Metrics API</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/FairwindsOps/goldilocks/refs/heads/master/pkg/dashboard/assets/images/favicon.ico"></td>
        <td><a href="https://goldilocks.docs.fairwinds.com/">Goldilocks</a></td>
        <td>Resource Recommendation Engine</td>
        <td></td>
    </tr>
    <tr>
        <td></td>
        <td><a href="https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler">Vertical Pod Autoscaler</a></td>
        <td>Workload Resource Scaler</td>
        <td>used exclusively for Goldilocks recommendations</td>
    </tr>
</table>

### 👨‍💻 User-Level

<table>
    <tr>
        <th></th>
        <th>Name</th>
        <th>Purpose</th>
        <th>Notes</th>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/pi-hole/docs/refs/heads/master/docs/images/logo.svg"></td>
        <td><a href="https://pi-hole.net/">Pi-hole</a></td>
        <td>Filtering DNS Proxy</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/nextcloud/server/refs/heads/master/core/img/favicon.png"></td>
        <td><a href="https://nextcloud.com/">Nextcloud</a></td>
        <td>File Storage and Management</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/dani-garcia/vaultwarden/refs/heads/main/resources/vaultwarden-icon.svg"></td>
        <td><a href="https://github.com/dani-garcia/vaultwarden">Vaultwarden</a></td>
        <td>API-compatible Password Manager</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/immich-app/immich/refs/heads/main/web/static/favicon.ico"></td>
        <td><a href="https://immich.app/">Immich</a></td>
        <td>Photo/Video Storage and Management</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/refs/heads/dev/docs/assets/favicon.png"></td>
        <td><a href="https://docs.paperless-ngx.com/">Paperless-ngx</a></td>
        <td>Document Management System</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/firefly-iii/firefly-iii/refs/heads/main/public/favicon.ico"></td>
        <td><a href="https://www.firefly-iii.org/">Firefly III</a></td>
        <td>Personal Finance Manager</td>
        <td>including <a href="https://github.com/firefly-iii/data-importer">importer</a> and <a href="https://github.com/cioraneanu/firefly-pico">pico</a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/TomBursch/kitchenowl/refs/heads/main/kitchenowl/web/favicon.ico"></td>
        <td><a href="https://kitchenowl.org/">KitchenOwl</a></td>
        <td>Recipe and Grocery Manager</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/gethomepage/homepage/refs/heads/dev/public/homepage.ico"></td>
        <td><a href="https://gethomepage.dev/">Homepage</a></td>
        <td>Application Dashboard</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/FreshRSS/freshrss.org/refs/heads/main/static/favicon.ico"></td>
        <td><a href="https://freshrss.org/index.html">Fresh-RSS</a></td>
        <td>RSS Aggregator</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/RSS-Bridge/rss-bridge/refs/heads/master/static/favicon.svg"></td>
        <td><a href="https://rss-bridge.org/">RSS-Bridge</a></td>
        <td>Unofficial RSS Feeds of ANY Source</td>
        <td><i>any</i> as long as you know some PHP</td>
    </tr>
    <tr>
        <td><img width="32" src="https://d21buns5ku92am.cloudfront.net/26628/documents/54546-1717072325-sc-logo-cloud-black-7412d7.svg"></td>
        <td><a href="https://github.com/anokfireball/soundcloud-scraper">Soundcloud Scraper</a></td>
        <td>Parser + Webhook for my Soundcloud Feed</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Stirling-Tools/Stirling-PDF/refs/heads/main/docs/stirling.svg"></td>
        <td><a href="https://www.stirlingpdf.com/">Stirling PDF</a></td>
        <td>Swiss-Army Knife for PDFs</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://cdn.jsdelivr.net/gh/selfhst/icons/svg/ubiquiti-unifi.svg"></td>
        <td><a href="https://ui.com/consoles">UniFi Network Application</a></td>
        <td>AP Administration and Management</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://cdn.jsdelivr.net/gh/selfhst/icons/svg/opnsense-v1.svg"></td>
        <td><a href="https://github.com/anokfireball/opnsense-ipv6-prefix-update">OPNsense Prefix Updater</a></td>
        <td>Update Network Configs with Newest Non-Static IPv6</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/n8n-io/n8n-docs/refs/heads/main/docs/_images/favicon.ico"></td>
        <td><a href="https://n8n.io/">n8n</a></td>
        <td>Workflow Automation</td>
        <td>freemium/open core</td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/jellyfin/jellyfin-web/refs/heads/master/src/assets/img/icon-transparent.png"></td>
        <td><a href="https://jellyfin.org/">Jellyfin</a></td>
        <td>Media Streaming and Management</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/qdm12/gluetun/refs/heads/master/doc/logo.svg"></td>
        <td><a href="https://github.com/qdm12/gluetun/">Gluetun</a></td>
        <td>VPN Gateway</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/qbittorrent/qBittorrent-website/refs/heads/master/src/favicon.svg"></td>
        <td><a href="https://www.qbittorrent.org/">qBittorrent</a></td>
        <td>Torrent Client</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/sabnzbd/sabnzbd/refs/heads/develop/interfaces/Config/templates/staticcfg/images/logo-small.svg"></td>
        <td><a href="https://sabnzbd.org/">SABnzbd</a></td>
        <td>Usenet Client</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Prowlarr/Prowlarr/refs/heads/develop/Logo/Prowlarr.svg"></td>
        <td><a href="https://prowlarr.com/">Prowlarr</a></td>
        <td>Torrent & Usenet Indexer Engine</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Radarr/Radarr/refs/heads/develop/Logo/Radarr.svg"></td>
        <td><a href="https://radarr.video/">Radarr</a></td>
        <td>Movie Management</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Sonarr/Sonarr/refs/heads/develop/Logo/Sonarr.svg"></td>
        <td><a href="https://sonarr.tv/">Sonarr</a></td>
        <td>TV Show Management</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Lidarr/Lidarr/refs/heads/develop/Logo/Lidarr.svg"></td>
        <td><a href="https://lidarr.audio/">Lidarr</a></td>
        <td>Music Management</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/FlareSolverr/FlareSolverr/refs/heads/master/resources/flaresolverr_logo.svg"></td>
        <td><a href="https://github.com/FlareSolverr/FlareSolverr">FlareSolverr</a></td>
        <td>Cloudflare Protection Bypass</td>
        <td></td>
    </tr>
</table>

## ☁️ Cloud Dependencies

While the ultimate goal is to have as self-sufficient of a setup as possible, some external services are still required for proper operation.

| Service                                                  | Purpose                                    | Notes                                                                    |
| -------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------ |
| [GitHub](https://github.com/)                            | Git Repository Hosting, GitOps Source      |                                                                          |
| [INWX](https://www.inwx.de/)                             | Domain Registrar                           |                                                                          |
| [Cloudflare](https://www.cloudflare.com/)                | Public DNS Auth Hosting                    |                                                                          |
| [netcup](https://www.netcup.de/)                         | Public Reverse-Proxy for Relevant Services | not _yet_ managed here since the number of public services is tiny       |
| [BackBlaze](https://www.backblaze.com/)                  | Cloud Storage for Backups                  | the "3" in 3-2-1 for the really important data                           |
| [TailScale](https://tailscale.com/)                      | Overlay VPN                                | used for split-horizon and a direct connection back home                 |
| VPN Provider                                             | VPN Gateway                                | different external IP for all the Linux ISOs                             |
