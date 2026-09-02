# Architecture & Conventions Reference

Cluster setup, service structure, and conventions. Companion to [README.md](README.md) which covers the high-level overview and tech stack.

## Table of Contents

- [Bootstrap Stages](#bootstrap-stages)
- [Flux GitOps Structure](#flux-gitops-structure)
- [Dependency Order](#dependency-order)
- [Networking](#networking)
- [Ingress Pattern](#ingress-pattern)
- [Storage Classes](#storage-classes)
- [Secrets Management](#secrets-management)
- [Variable Substitution](#variable-substitution)
- [Backup Strategy](#backup-strategy)
- [Application Patterns](#application-patterns)
- [Observability](#observability)
- [Dependency Update Automation](#dependency-update-automation)
- [Public Gateway](#public-gateway)

---

## Bootstrap Stages

### Stage 1: cloud-init (`cloud-init/`)

`setup.sh` generates the autoinstall and netboot files. No further interaction needed after triggering the netboot.

### Stage 2: Cluster Ansible (`ansible/cluster/`)

Single playbook (`cluster.yaml`) that runs six roles against all cluster nodes:

```
os_base      → base OS config (users, packages, sysctl, etc.)
os_check     → OS-level checks/assertions
os_power     → power management settings
k8s_cluster  → kubeadm install + init/join, Calico CNI, kube-vip
k8s_longhorn → prerequisites for Longhorn (open-iscsi, disk prep)
k8s_flux     → Flux bootstrap + SOPS key injection
```

API server authentication uses Authentik as the OIDC provider with Pinniped handling the kubeconfig-based OIDC flow (configured in `flux/system/infrastructure-configs/`).

### Stage 3: Flux GitOps (`flux/`)

See [Flux GitOps Structure](#flux-gitops-structure) below.

### Stage 4: Gateway Ansible (`ansible/gateway/`)

```
os_base       → base OS config
os_check      → OS-level checks/assertions
tailscale     → Tailscale mesh VPN for connectivity back to the cluster
ansible-pull  → GitOps outside k8s (ansible-pull + SOPS)
caddy         → Caddy reverse proxy built from source with Cloudflare/netcup/porkbun DNS plugins
```

---

## Flux GitOps Structure

All cluster state lives under `flux/`. The entry point is `flux/clusters/homelab/` which defines the root Flux Kustomizations.

```
flux/
  clusters/homelab/       # Root kustomizations (entry point for Flux)
    flux-system/          # Flux itself (bootstrapped by Ansible)
    infrastructure.yaml   # All system-level kustomizations
    secrets.yaml          # Secrets kustomization
    apps.yaml             # User apps kustomization
  namespaces/             # Namespace definitions
  repositories/           # HelmRepository definitions (one file per chart source)
  secrets/                # SOPS-encrypted Kubernetes Secrets
  system/
    infrastructure-controllers/   # Core infra Helm releases (metallb, cert-manager, etc.)
    infrastructure-configs/       # CRD instances for infra (IP pools, ClusterIssuers, etc.)
    app-controllers/              # Operator/controller Helm releases (longhorn, cnpg, etc.)
    app-configs/                  # Configuration for operators (StorageClasses, Gateways, etc.)
    rbac/                         # ClusterRoleBindings, etc.
  apps/                   # User-facing applications (one file or directory per app)
```

---

## Dependency Order

Flux Kustomizations are ordered via `dependsOn`. The full chain from first to last:
```
secrets               (no deps; SOPS secrets deployed independently)
system-namespaces     (no deps; namespace creation)
repositories          (no deps; HelmRepository sources)
envoy-gateway-crds    → repositories
system-infrastructure-controllers  → repositories, system-namespaces, envoy-gateway-crds
system-infrastructure-configs      → system-infrastructure-controllers
system-app-controllers             → system-infrastructure-configs
system-app-configs                 → system-app-controllers
system-rbac            → system-namespaces (independent branch)
apps                   → system-app-configs
```

Two additional CRD kustomizations exist inside the above directories: `csi-snapshotter-crds` (in `system-infrastructure-configs`) and `k8up-crds` (in `system-app-controllers`), each prepared before their controller kustomization applies.

All kustomizations reconcile on a 1h interval with a 1m retry and 5m timeout. SOPS decryption and `cluster-secrets` variable substitution are applied at every level from `system-infrastructure-controllers` onward.

---

## Networking

### MetalLB

MetalLB runs in L2/ARP mode (single-node VIP announcement, not true load balancing). Four dedicated IP pools, all dual-stack:

| Pool name | IPv4 | IPv6 | Used by |
|-----------|------|------|---------|
| `dns-vip` | 192.168.1.3 | fd08:192:168:1::3 | Pi-hole DNS service |
| `http-vip` | 192.168.1.4 | fd08:192:168:1::4 | unused (reserved) |
| `default-vip` | 192.168.1.5 | fd08:192:168:1::5 | UniFi controller |
| `envoy-gateway-vip` | 192.168.1.6 | fd08:192:168:1::6 | Envoy Gateway |

All pools are advertised on `eth0`.

### Ingress Controllers

**Envoy Gateway is the sole ingress controller.** The ingress-nginx migration is complete; ingress-nginx has been removed.

Envoy Gateway uses the Gateway API with a shared `Gateway` and per-app `ListenerSet` (see [Ingress Pattern](#ingress-pattern)). All services must use this pattern.

### external-dns

Split-horizon DNS is implemented via external-dns with the [OPNsense webhook](https://github.com/crutonjohn/external-dns-opnsense-webhook): internal DNS records point to the internal VIP, while public DNS (Cloudflare) points to the public gateway.

### cert-manager
A single `ClusterIssuer` named `letsencrypt` using ACME DNS-01 challenge via Cloudflare. Certificates are requested per-app in the `envoy-gateway-system` namespace.

### Tailscale

The Tailscale Kubernetes operator runs in-cluster. Services that should be reachable over Tailscale get these annotations:

```yaml
tailscale.com/expose: "true"
tailscale.com/hostname: homelab-<appname>
```

---

## Ingress Pattern

Every user-facing app exposed via Envoy Gateway follows this consistent pattern. All five resources are typically co-located in the app's YAML file:

### 1. Certificate (in `envoy-gateway-system` namespace)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: <app>-tls
  namespace: envoy-gateway-system
spec:
  secretName: <app>-tls
  dnsNames:
    - <app>.${SERVICE_DOMAIN}
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt
```

### 2. ListenerSet (app namespace, owns the HTTPS listener)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: ListenerSet
metadata:
  name: <app>
  namespace: <app-namespace>
spec:
  parentRef:
    kind: Gateway
    name: shared
    namespace: envoy-gateway-system
  listeners:
    - name: https
      hostname: <app>.${SERVICE_DOMAIN}
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: <app>-tls
            namespace: envoy-gateway-system
```

### 3. ReferenceGrant (`envoy-gateway-system`, permits cross-namespace TLS secret reference)

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: <app>-listenerset-to-<app>-tls
  namespace: envoy-gateway-system
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      namespace: <app-namespace>
  to:
    - group: ""
      kind: Secret
      name: <app>-tls
```

### 4. HTTPRoute (app namespace, routes to the backend)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>
  namespace: <app-namespace>
spec:
  parentRefs:
    - kind: ListenerSet
      name: <app>
      namespace: <app-namespace>
      sectionName: https
  hostnames:
    - <app>.${SERVICE_DOMAIN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
```

### 5. HTTP→HTTPS redirect HTTPRoute (in the app's namespace)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>-http-redirect
  namespace: <app-namespace>
spec:
  parentRefs:
    - kind: Gateway
      name: shared
      namespace: envoy-gateway-system
      sectionName: http
  hostnames:
    - <app>.${SERVICE_DOMAIN}
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

---

## Storage Classes

Four storage classes are available. Choose based on resilience and data permanence requirements:

| Class | Provisioner | Replicas | Reclaim | Use for |
|-------|-------------|----------|---------|---------|
| `cluster-scratch` | Longhorn | 1 | Delete | Caches, ephemeral data, incomplete downloads |
| `cluster-replicated` | Longhorn | 3 | Retain | App config, persistent data, databases |
| `nas-scratch-ssd` | democratic-csi (NFS, SSD pool) | N/A | Delete | Scratch NFS volumes on fast storage |
| `nas-replicated-hdd` | democratic-csi (NFS, HDD pool) | N/A | Retain | Large persistent NFS volumes (e.g. Prometheus TSDB) |

**Longhorn** backs volumes with local node storage. All Longhorn volumes participate in a daily backup to the NAS NFS share (`nfs://192.168.1.2:/mnt/tank/Backup/longhorn`). The `cluster-replicated` class additionally runs a `daily-backup` recurring job.

**democratic-csi** provisions NFS datasets directly on the TrueNAS NAS via its API:
- SSD pool: `scratch/k8s` dataset
- HDD pool: `tank/Scratch/k8s` dataset

For NAS-hosted data that exists outside Kubernetes (photos, media, downloads), volumes are mounted directly as `nfs` type in the pod spec or as a static `PersistentVolume` with `storageClassName: ""`.

---

## Secrets Management

SOPS with an `age` key is used for all secrets. The age public key is committed; the private key is held only on the operator's machine and injected into the cluster by Ansible as the `sops-age` Kubernetes Secret in `flux-system`.

Two encryption rules in `.sops.yaml`:

| Path pattern | Behavior |
|---|---|
| `ansible/.*\.sops\.ya?ml` | Fully encrypted |
| `flux/secrets/.+\.sops\.ya?ml` | only data fields encrypted; `unencrypted_regex: "^(apiVersion\|kind\|metadata\|type)$"` |

All Flux Kustomizations (from `system-infrastructure-controllers` onwards) include:

```yaml
decryption:
  provider: sops
  secretRef:
    name: sops-age
```

---

## Variable Substitution

A `cluster-secrets` Kubernetes Secret holds cluster-wide variables. All Flux Kustomizations from `system-infrastructure-controllers` onwards include:

```yaml
postBuild:
  substituteFrom:
    - kind: Secret
      name: cluster-secrets
```

This allows `${VAR}` substitution in any manifests. Known variables include:

| Variable | Purpose |
|---|---|
| `${SERVICE_DOMAIN}` | Base domain for all service hostnames |
| `${SMTP_HOST}` | Mail relay hostname |
| `${FREENAS_USERNAME}` | TrueNAS API/SSH username for democratic-csi |
| `${FREENAS_PASSWORD}` | TrueNAS API/SSH password for democratic-csi |

The `cluster-secrets` Secret itself is in `flux/secrets/cluster-secrets.sops.yaml` and deployed by the `secrets` Kustomization.

---

## Backup Strategy

Backups use a combination of Longhorn's built-in backup and [k8up](https://k8up.io/) (restic-based) targeting Backblaze B2 (S3-compatible).

### Database backups (k8up + PreBackupPod)

Apps with a CloudNativePG database follow this pattern:

1. A `PreBackupPod` runs `pg_dumpall` against the CNPG `*-rw` service.
2. A k8up `Schedule` backs up the pod's output to a dedicated Backblaze bucket every 6 hours.

```
schedule: "MM H/6 * * *"    # staggered per app to avoid simultaneous runs
```

Retention for all database backups:
```
keepHourly: 6 / keepDaily: 14 / keepWeekly: 12 / keepMonthly: 6 / keepYearly: 2
```

### PVC data backups (k8up label-based)

PVCs annotated with `k8up.io/backup: "true"` and a `backup: <app>-data` label are picked up by a corresponding k8up `Schedule`. Exclusion patterns (e.g. thumbnails, logs) are specified via `k8up.io/backup-restic-args` annotations on the PVC.

### Longhorn volume backups

All volumes in `cluster-replicated` class participate in a `daily-backup` recurring job (23:45 daily, 7-day retention) and weekly filesystem trim (Sunday 00:00).

---

## Application Patterns

When adding a new service, add an entry to the Applications table in [README.md](README.md), following the existing format (logo, name, purpose, uptime badge if applicable).

### Chart selection

| Pattern | When used | Examples |
|---------|-----------|---------|
| App's own Helm chart | App publishes a maintained chart | Nextcloud, Immich, Pi-hole, Kube-prometheus-stack |
| [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) | No upstream chart or chart is poor quality | arr-stack, qBittorrent, SABnzbd, RSS-Bridge, most small apps |

### Database pattern: CloudNativePG (PostgreSQL)

Apps requiring PostgreSQL use a CloudNativePG `Cluster` resource. **Do not use app-chart-native database deployments** (e.g. `postgresql.enabled: true` in a Helm chart). The operator gives consistent backup coverage and credential management. Standard pattern:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <app>-postgresql
  namespace: <app-namespace>
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:<version>@sha256:<digest>
  instances: 1
  managed:
    services:
      disabledDefaultServices: ["ro", "r"]   # only the -rw service is created
    roles:
      - name: backup                          # always present; used by k8up PreBackupPod
        passwordSecret:
          name: postgres-backup-user
        login: true
        superuser: false
        inRoles:
          - pg_read_all_data
  bootstrap:
    initdb:
      database: <app>
      owner: <app>
      secret:
        name: <app>-postgres-user
  storage:
    size: <N>Gi
    storageClass: cluster-replicated
```

- **Single instance**: no replicas at homelab scale; HA comes from Longhorn 3x volume replication
- **Only the `-rw` service**: `ro` and `r` services are disabled; apps connect to `<cluster-name>-rw`
- **Image pinned by digest**: all CNPG images use `image:tag@sha256:digest`
- **Backup role always present**: a `backup` user with `pg_read_all_data` is created in every cluster; used by the k8up `PreBackupPod` to run `pg_dumpall`
- **`cluster-replicated` storage**: all database volumes use the 3-replica Longhorn class with Retain policy

#### Special cases

| App | Deviation | Reason |
|-----|-----------|--------|
| Immich | Uses `ghcr.io/tensorchord/cloudnative-vectorchord` image | Requires `pgvector` and `vchord` extensions for ML similarity search |
| Immich | `superuser: true` on the app role | Required by immich migrations |
| Immich | `postInitSQL` to create extensions | `vector`, `vchord`, `cube`, `earthdistance` |

### Database pattern: MongoDB Community Operator

UniFi uses the MongoDB Community Operator (`MongoDBCommunity` CRD) instead of CloudNativePG:

```yaml
apiVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
metadata:
  name: <app>-mongodb
  namespace: <app-namespace>
spec:
  members: 1
  type: ReplicaSet       # MongoDB requires ReplicaSet type even for single-member
  version: "<version>"
  security:
    authentication:
      modes: [SCRAM]
  statefulSet:
    spec:
      volumeClaimTemplates:
        - metadata:
            name: data-volume
          spec:
            storageClassName: cluster-replicated
```

- Single-member ReplicaSet (MongoDB Community only supports ReplicaSet topology)
- Storage on `cluster-replicated`
- Credentials injected via `passwordSecretRef` pointing to existing Secrets

### Database backup pattern

PostgreSQL and MongoDB databases are both backed up via k8up. For CNPG (PostgreSQL):

1. A `PreBackupPod` defines the backup command:
   ```yaml
   spec:
     backupCommand: sh -c 'PGHOST="$POSTGRES_HOST" PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall --clean'
     pod:
       spec:
         containers:
           - image: postgres:<version>-alpine@sha256:<digest>
             env:
               - name: POSTGRES_HOST
                 value: <cluster-name>-rw
               - name: POSTGRES_USER
                 valueFrom:
                   secretKeyRef:
                     name: postgres-backup-user   # the 'backup' managed role
                     key: username
   ```

2. A k8up `Schedule` targets the PreBackupPod by label and runs every 6 hours (staggered per app to avoid simultaneous backup runs).

### Namespace layout

| Namespace | Contents |
|---|---|
| `default` | Most user-facing apps (Nextcloud, Immich, Pi-hole, etc.) |
| `arrchive` | Media stack: qBittorrent (with Gluetun VPN sidecar), SABnzbd, Jellyfin |
| `flux-system` | Flux controllers |
| `envoy-gateway-system` | Envoy Gateway + TLS certificates |
| `longhorn-system` | Longhorn storage |
| `democratic-csi-system` | democratic-csi drivers |
| `metallb-system` | MetalLB |
| `cert-manager-system` | cert-manager |
| `external-dns-system` | external-dns |
| `monitoring-system` | Prometheus, Alertmanager, Grafana, Loki, Promtail |
| `cloudnative-pg-system` | CloudNativePG operator |
| `mongodb-system` | MongoDB Kubernetes operator |
| `k8up-system` | k8up backup/restore |
| `spegel-system` | Spegel |
| `goldilocks-system` | Goldilocks |
| `tailscale` | Tailscale operator |
| `kyverno-system` | Kyverno policy engine |
| `renovate-system` | Renovate bot |

### VPN sidecar pattern (qBittorrent)

Containers requiring VPN egress use Gluetun as a sidecar in the same pod:

- `gluetun` container gets `NET_ADMIN` capability and VPN credentials from `gluetun-secrets`
- Main app container shares the network namespace (traffic goes through Gluetun)
- A `port-forward` sidecar manages the forwarded port between Gluetun and qBittorrent
- A `logs` sidecar tails the app log file for visibility

### Reloader

Services whose pods should restart when their ConfigMap or Secret changes carry:

```yaml
annotations:
  reloader.stakater.com/auto: "true"
```

The [Reloader](https://docs.stakater.com/reloader/) controller watches for changes and triggers rolling restarts automatically.

### Grafana dashboards

Grafana dashboards are provisioned as ConfigMaps with the sidecar label:

```yaml
labels:
  grafana_dashboard: "1"
annotations:
  grafana_dashboard_folder: <folder-name>
```

The Grafana sidecar picks these up automatically from any namespace.

---

## Observability

The monitoring stack consists of:

| Component | Role |
|---|---|
| kube-prometheus-stack | Prometheus + Alertmanager + default dashboards (Grafana deployed separately) |
| Grafana | Dashboard UI, deployed as its own HelmRelease |
| Loki | Log aggregation and storage |
| Promtail | Log shipping from nodes/pods to Loki |
| Scrutiny | SMART disk health monitoring |

Prometheus is configured with:
- 90-day retention, 250 GiB size limit
- Storage on `nas-replicated-hdd` (250 Gi PVC on TrueNAS HDD pool)
- `podMonitorSelectorNilUsesHelmValues: false` and `serviceMonitorSelectorNilUsesHelmValues: false`: Prometheus picks up all ServiceMonitors/PodMonitors cluster-wide regardless of labels

Apps that export Prometheus metrics include a `ServiceMonitor` with:
```yaml
labels:
  release: kube-prometheus-stack
```

---

## Dependency Update Automation

[Renovate Bot](https://www.mend.io/renovate/) runs in-cluster and manages updates across the entire repo.

### Auto-merge policy

| Condition | Auto-merge |
|---|---|
| `flux/**`: patch or digest update, non-pre-1.0 package | Yes |
| `flux/**`: renovate or kube-prometheus-stack minor/patch/digest | Yes |
| Everything else | No (PR created, manual merge) |

### Always-manual packages

`longhorn`, `kubernetes`, `containerd`, `external-dns`, `scrutiny`, `longhorn/csi-snapshotter`

### Custom version tracking

Renovate uses regex custom managers to track versions that are not in standard Helm/Docker fields:

- k8s, containerd, Calico, kube-vip: `ansible/cluster/roles/k8s_cluster/vars/main.yaml`
- Flux: `ansible/cluster/roles/k8s_flux/vars/main.yaml`
- Caddy, Go, SOPS, Caddy DNS plugins: `ansible/gateway/roles/*/vars/main.yaml`
- CloudNativePG PostgreSQL image versions (per major version): app YAML files
- Pinniped: tracked via comment annotation in the manifest file

---

## Public Gateway

A VPS at netcup acts as the public-facing entry point for select services. It connects back to the cluster exclusively via Tailscale and forwards traffic using Caddy.

- Caddy is built from source with DNS provider plugins (Cloudflare, netcup, porkbun) for ACME TLS
- Configuration is managed via `ansible-pull` (GitOps without Kubernetes)
- SOPS is used on the gateway, same as the cluster
- Only specific services are exposed; the internal cluster is not otherwise reachable from the internet
