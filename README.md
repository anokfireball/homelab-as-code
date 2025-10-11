<div align="center">

![Homelab-as-Code logo](logo.png "Homelab-as-Code logo")

<img src="https://gatus.kthxbye.cyou/api/v1/endpoints/k8s-homelab_loadbalancer-[http]/health/badge.svg" alt="Cluster Health">
<a href="https://gatus.kthxbye.cyou/endpoints/k8s-homelab_loadbalancer-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/k8s-homelab_loadbalancer-[http]/uptimes/30d/badge.svg" alt="Cluster Uptime"></a>

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
  This includes only the very basic OS-level configuration required for the other stages of this workflow.
  The contained shell script creates all files required to install the OS via [network boot](https://ubuntu.com/server/docs/how-to-netboot-the-server-installer-on-amd64) and without user interaction.
  _Triggering_ the network-boot installation is out-of-scope for the moment.
  After completion of the cloud-init [autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/intro-to-autoinstall.html), all nodes reboot and are ready to accept SSH connections.
- [ansible/cluster](ansible/cluster) contains the stage 2 system configuration for the cluster nodes.
  This includes a range of tasks including power management, networking setup, and most importantly bootstrapping the kubernetes cluster using [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/).
  The included Ansible playbook performs the required tasks on the nodes via SSH and a dedicated Ansible user created in the previous step.
  After completion of this stage, the Kubernetes cluster is set up with [HA](https://kube-vip.io/) control planes, joined worker nodes, dual-stack [CNI](https://www.tigera.io/tigera-products/calico/), almost working [OIDC authn](https://dexidp.io/), and last but not least a bootstrapped [GitOps](https://fluxcd.io/) setup that is ready to start reconciling.
- [flux](flux) contains the final stage 3 GitOps cluster configuration.
  This includes everything running _inside_ kubernetes in the cluster and ranges from basic system infrastructure like [load balancer](https://metallb.io/), [ingress](https://kubernetes.github.io/ingress-nginx/), and [CSI](https://longhorn.io/) to more user-style applications such as [password manager](https://bitwarden.com/) and [file management](https://nextcloud.com/) apps.
  The included Flux kustomizations are automatically installed and/or reconciled on the cluster without* user interaction.
  This process is staggered since there is an inherent dependency between some of the components.
  After completion of this stage, the cluster is fully set up and ready for use.

In addition to the core homelab IaC, there is one more loosely related stage:
- [ansible/gateway](ansible/gateway) contains system configuration for a remotely hosted ingress gateway used to expose select services publicly.
  This includes setup of [GitOps](https://docs.ansible.com/ansible/latest/cli/ansible-pull.html) outside of Kubernetes, [mesh networking](https://tailscale.com/) outside of Kubernetes, and a [reverse proxy](https://caddyserver.com/) with ACME support.
  The included Ansible playbook performs the required tasks on a manually provisioned gateway via SSH and a dedicated Ansible user also created manually.
  After completion of this stage, the public gateway is set up and ready to reverse proxy connections to the cluster.

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
| [SOPS](https://getsops.io/)                                          | Secrets Management                     | [age](https://age-encryption.org/) rather than PGP, but not any more user-friendly |

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
        <td>split-horizon realized using <a href="https://github.com/crutonjohn/external-dns-opnsense-webhook">opnsense webhook</a></td>
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
        <td><a href="https://kyverno.io/">Kyverno</a></td>
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
        <td>Monitoring and Observability</td>
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
        <td><img height="32" width="32" src="https://raw.githubusercontent.com/kubernetes-sigs/descheduler/refs/heads/master/assets/logo/descheduler-stacked-color.png"></td>
        <td><a href="https://sigs.k8s.io/descheduler">descheduler</a></td>
        <td>Pod Eviction for Node Balancing</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/stakater/Reloader/refs/heads/master/theme_override/resources/assets/images/favicon.svg"></td>
        <td><a href="https://docs.stakater.com/reloader/">reloader</a></td>
        <td>Hot-Reload for ALL Workloads</td>
        <td></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/dexidp/website/refs/heads/main/static/img/logos/dex-glyph-color.svg"></td>
        <td><a href="https://dexidp.io/">Dex</a></td>
        <td>OIDC Provider</td>
        <td>used for API server authentication</td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/tailscale/tailscale/refs/heads/main/client/web/src/assets/icons/tailscale-icon.svg"></td>
        <td><a href="https://github.com/tailscale/tailscale/tree/main/cmd/k8s-operator">Tailscale</a></td>
        <td>Overlay Mesh VPN Operator</td>
        <td></td>
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
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_pi-hole-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_pi-hole-[http]/uptimes/30d/badge.svg" alt="Pi-hole Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/nextcloud/server/refs/heads/master/core/img/favicon.png"></td>
        <td><a href="https://nextcloud.com/">Nextcloud</a></td>
        <td>File Storage and Management</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_nextcloud-[http---public]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_nextcloud-[http---public]/uptimes/30d/badge.svg" alt="Nextcloud Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/dani-garcia/vaultwarden/refs/heads/main/resources/vaultwarden-icon.svg"></td>
        <td><a href="https://github.com/dani-garcia/vaultwarden">Vaultwarden</a></td>
        <td>API-compatible Password Manager</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_bitwarden-[http---public]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_bitwarden-[http---public]/uptimes/30d/badge.svg" alt="Vaultwarden Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/immich-app/immich/refs/heads/main/web/static/favicon.ico"></td>
        <td><a href="https://immich.app/">Immich</a></td>
        <td>Photo/Video Storage and Management</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_immich-[http---public]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_immich-[http---public]/uptimes/30d/badge.svg" alt="Immich Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/refs/heads/dev/docs/assets/favicon.png"></td>
        <td><a href="https://docs.paperless-ngx.com/">Paperless-ngx</a></td>
        <td>Document Management System</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_paperless-ngx-[http---public]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_paperless-ngx-[http---public]/uptimes/30d/badge.svg" alt="Paperkess-ngx Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/firefly-iii/firefly-iii/refs/heads/main/public/favicon.ico"></td>
        <td><a href="https://www.firefly-iii.org/">Firefly III</a></td>
        <td>Personal Finance Manager</td>
        <td>including <a href="https://github.com/firefly-iii/data-importer">importer</a> and <a href="https://github.com/cioraneanu/firefly-pico">pico</a><br><a href="https://gatus.kthxbye.cyou/endpoints/services_firefly-iii-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_firefly-iii-[http]/uptimes/30d/badge.svg" alt="Firefly III Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/TomBursch/kitchenowl/refs/heads/main/kitchenowl/web/favicon.ico"></td>
        <td><a href="https://kitchenowl.org/">KitchenOwl</a></td>
        <td>Recipe and Grocery Manager</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_kitchenowl-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_kitchenowl-[http]/uptimes/30d/badge.svg" alt="KitchenOwl Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/gethomepage/homepage/refs/heads/dev/public/homepage.ico"></td>
        <td><a href="https://gethomepage.dev/">Homepage</a></td>
        <td>Application Dashboard</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_homepage-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_homepage-[http]/uptimes/30d/badge.svg" alt="Homepage Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/FreshRSS/freshrss.org/refs/heads/main/static/favicon.ico"></td>
        <td><a href="https://freshrss.org/index.html">Fresh-RSS</a></td>
        <td>RSS Aggregator</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_fresh-rss-[http---public]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_fresh-rss-[http---public]/uptimes/30d/badge.svg" alt="Fresh-RSS Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/RSS-Bridge/rss-bridge/refs/heads/master/static/favicon.svg"></td>
        <td><a href="https://rss-bridge.org/">RSS-Bridge</a></td>
        <td>Unofficial RSS Feeds of ANY Source</td>
        <td><i>any</i> as long as you know some PHP<br><a href="https://gatus.kthxbye.cyou/endpoints/services_rss-bridge-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_rss-bridge-[http]/uptimes/30d/badge.svg" alt="RSS-Bridge Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://d21buns5ku92am.cloudfront.net/26628/documents/54546-1717072325-sc-logo-cloud-black-7412d7.svg"></td>
        <td><a href="https://github.com/anokfireball/soundcloud-scraper">Soundcloud Scraper</a></td>
        <td>Parser + Webhook for my Soundcloud Feed</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_soundcloud-scraper-[push]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_soundcloud-scraper-[push]/uptimes/30d/badge.svg" alt="Soundcloud Scraper Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Stirling-Tools/Stirling-PDF/refs/heads/main/docs/stirling.svg"></td>
        <td><a href="https://www.stirlingpdf.com/">Stirling PDF</a></td>
        <td>Swiss-Army Knife for PDFs</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_stirling-pdf-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_stirling-pdf-[http]/uptimes/30d/badge.svg" alt="Stirling PDF Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/excalidraw/excalidraw/refs/heads/master/public/favicon.svg"></td>
        <td><a href="https://excalidraw.com/">Excalidraw</a></td>
        <td>Virtual Whiteboard</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_excalidraw-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_excalidraw-[http]/uptimes/30d/badge.svg" alt="Excalidraw Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://cdn.jsdelivr.net/gh/selfhst/icons/svg/ubiquiti-unifi.svg"></td>
        <td><a href="https://ui.com/consoles">UniFi Network Application</a></td>
        <td>AP Administration and Management</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_unifi-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_unifi-[http]/uptimes/30d/badge.svg" alt="UniFi Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://cdn.jsdelivr.net/gh/selfhst/icons/svg/opnsense-v1.svg"></td>
        <td><a href="https://github.com/anokfireball/opnsense-ipv6-prefix-update">OPNsense Prefix Updater</a></td>
        <td>Update Network Configs with Latest Non-Static IPv6</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/petrus_opnsense-prefix-update-[push]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/petrus_opnsense-prefix-update-[push]/uptimes/30d/badge.svg" alt="OPNsense Prefix Updater Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/n8n-io/n8n-docs/refs/heads/main/docs/_images/favicon.ico"></td>
        <td><a href="https://n8n.io/">n8n</a></td>
        <td>Workflow Automation</td>
        <td>freemium/open core<br><a href="https://gatus.kthxbye.cyou/endpoints/services_n8n-[http---public]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_n8n-[http---public]/uptimes/30d/badge.svg" alt="n8n Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/jellyfin/jellyfin.org/refs/heads/master/static/images/icon-transparent.svg"></td>
        <td><a href="https://jellyfin.org/">Jellyfin</a></td>
        <td>Media Streaming and Management</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_jellyfin-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_jellyfin-[http]/uptimes/30d/badge.svg" alt="Jellyfin Uptime"></a></td>
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
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_qbittorrent-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_qbittorrent-[http]/uptimes/30d/badge.svg" alt="qBittorrent Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/sabnzbd/sabnzbd/refs/heads/develop/interfaces/Config/templates/staticcfg/images/logo-small.svg"></td>
        <td><a href="https://sabnzbd.org/">SABnzbd</a></td>
        <td>Usenet Client</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_sabnzbd-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_sabnzbd-[http]/uptimes/30d/badge.svg" alt="SABnzbd Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Prowlarr/Prowlarr/refs/heads/develop/Logo/Prowlarr.svg"></td>
        <td><a href="https://prowlarr.com/">Prowlarr</a></td>
        <td>Torrent & Usenet Indexer Engine</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_prowlarr-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_prowlarr-[http]/uptimes/30d/badge.svg" alt="Prowlarr Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Radarr/Radarr/refs/heads/develop/Logo/Radarr.svg"></td>
        <td><a href="https://radarr.video/">Radarr</a></td>
        <td>Movie Management</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_radarr-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_radarr-[http]/uptimes/30d/badge.svg" alt="Radarr Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Sonarr/Sonarr/refs/heads/develop/Logo/Sonarr.svg"></td>
        <td><a href="https://sonarr.tv/">Sonarr</a></td>
        <td>TV Show Management</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_sonarr-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_sonarr-[http]/uptimes/30d/badge.svg" alt="Sonarr Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/Lidarr/Lidarr/refs/heads/develop/Logo/Lidarr.svg"></td>
        <td><a href="https://lidarr.audio/">Lidarr</a></td>
        <td>Music Management</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_lidarr-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_lidarr-[http]/uptimes/30d/badge.svg" alt="Lidarr Uptime"></a></td>
    </tr>
    <tr>
        <td><img width="32" src="https://raw.githubusercontent.com/FlareSolverr/FlareSolverr/refs/heads/master/resources/flaresolverr_logo.svg"></td>
        <td><a href="https://github.com/FlareSolverr/FlareSolverr">FlareSolverr</a></td>
        <td>Cloudflare Protection Bypass</td>
        <td><a href="https://gatus.kthxbye.cyou/endpoints/services_flaresolverr-[http]"><img src="https://gatus.kthxbye.cyou/api/v1/endpoints/services_flaresolverr-[http]/uptimes/30d/badge.svg" alt="FlareSolverr Uptime"></a></td>
    </tr>
</table>

## ☁️ Cloud Dependencies

While the ultimate goal is to have as self-sufficient of a setup as possible, some external services are still required for proper operation.

| Service                                   | Purpose                                  | Notes                                               |
| ----------------------------------------- | ---------------------------------------- | --------------------------------------------------- |
| [GitHub](https://github.com/)             | Git Repository Hosting, GitOps Source    |                                                     |
| [INWX](https://www.inwx.de/)              | Domain Registrar                         |                                                     |
| [Cloudflare](https://www.cloudflare.com/) | Public DNS Auth Hosting                  |                                                     |
| [Let's Encrypt](https://letsencrypt.org/) | SSL Certificates                         |                                                     |
| [netcup](https://www.netcup.de/)          | Public Reverse-Proxy for Select Services |                                                     |
| [BackBlaze](https://www.backblaze.com/)   | Cloud Storage for Backups                | the "3" in 3-2-1 for the really important data      |
| [TailScale](https://tailscale.com/)       | Overlay Mesh VPN                         | used for split-horizon and a direct route back home |
| VPN Provider                              | VPN Gateway                              | unassociated external IP for all the Linux ISOs     |
