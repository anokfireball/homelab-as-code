# Cluster operations runbook

Step-by-step procedures for the two manual node workflows:

- [Kubernetes / containerd / kube-vip upgrade](#kubernetes-upgrade-upgradeyaml) (`upgrade.yaml`)
- [OS maintenance: apt updates and reboots](#os-maintenance-maintenanceyaml) (`maintenance.yaml`)

[ARCHITECTURE.md](../../ARCHITECTURE.md#stage-2-cluster-ansible-ansiblecluster) describes what the playbooks do internally. This file covers how to run them.

## Ground rules

- One workflow at a time, never both at once and never while a node is already cordoned for something else.
- Never let apt install a backlog on a live node. Planned updates and reboots go through `maintenance.yaml`, which drains the node first. Unattended-upgrades only installs security updates and never reboots.
- Every run is resumable. If a run fails or you abort it, fix the cause and re-run the same command; the playbooks work out from the cluster state what is left to do.
- Do not reboot or drain nodes by hand while a run is in progress.

## Prerequisites (once per workstation)

```sh
cd ansible/cluster
ansible-galaxy collection install -r requirements.yaml
```

- SSH: the inventory uses user `ansible` with key `~/.ssh/id_ed25519_ansible`; that user has passwordless sudo on all nodes.
- `kubectl` and `jq` installed locally.
- Run every command below from `ansible/cluster/` (relative inventory and `ansible.cfg`).
- Work from an up-to-date, clean checkout of `main` (`git switch main && git pull`). A playbook run uses the files on disk, so do not edit or switch the checkout while it is running.

The playbooks fetch `/etc/kubernetes/admin.conf` from controlplane1 to `~/.kube/homelab-admin.conf` and use it for every kubectl call. It talks to the API VIP directly, so it keeps working when Pinniped/Authentik are down. Use the same file for manual checks:

```sh
export KUBECONFIG=~/.kube/homelab-admin.conf
```

## Before every run

1. **Health:** all nodes `Ready`, no degraded Longhorn volumes, every CNPG cluster healthy, no pods stuck:

   ```sh
   kubectl get nodes
   kubectl -n longhorn-system get volumes.longhorn.io \
     -o custom-columns=NAME:.status.kubernetesStatus.pvcName,STATE:.status.state,ROBUSTNESS:.status.robustness
   kubectl get clusters.postgresql.cnpg.io -A
   kubectl get pods -A | grep -vE 'Running|Completed'
   ```

   The preflight checks Longhorn only once, without waiting. If a volume is still `degraded` (for example while it rebuilds after the previous node), wait until all are `healthy` and re-run.

2. **etcd snapshot** (on controlplane1, then copy it off the node):

   ```sh
   ssh -i ~/.ssh/id_ed25519_ansible ansible@192.168.1.211 'sudo bash -s' <<'EOF'
   C="crictl --runtime-endpoint unix:///run/containerd/containerd.sock"
   f=etcd-$(date +%Y%m%d-%H%M).db
   $C exec $($C ps -q --name '^etcd$') etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key snapshot save /var/lib/etcd/$f
   mkdir -p /var/backups/etcd && mv /var/lib/etcd/$f /var/backups/etcd/ && ls -l /var/backups/etcd/$f
   EOF
   scp -i ~/.ssh/id_ed25519_ansible ansible@192.168.1.211:/var/backups/etcd/etcd-<timestamp>.db ~/.kube/
   ```

## Kubernetes upgrade (`upgrade.yaml`)

Upgrades kubelet/kubeadm/kubectl, containerd, the containerd config and kube-vip on existing nodes to the versions pinned in [`group_vars/all/versions.yaml`](group_vars/all/versions.yaml).

1. **Set the target versions.** Merge the Renovate PR, or edit `versions.yaml` in a PR:
   - `k8s_version` may move by **one minor version** per run (1.37.x → 1.38.x). For several minors, repeat the whole procedure once per minor, with a separate PR each.
   - When bumping the minor, add the new minor to `containerd_supported` (from <https://containerd.io/releases/#kubernetes-support>). The preflight refuses any k8s/containerd pair that is not listed.
   - `containerd_version` and `kube_vip_version` can change in the same run or on their own.
2. **Do the [checks before every run](#before-every-run).**
3. **Preflight and plan.** This changes nothing in the cluster:

   ```sh
   ansible-playbook -i inventory.ini upgrade.yaml --tags preflight
   ```

   It fails on: more than one minor step, an unsupported containerd pair, pinned packages missing from apt, unhealthy API/etcd/Longhorn, nodes not `Ready`, single-instance CNPG clusters without `enablePDB: false`, and a wrong Longhorn `nodeDrainPolicy`. Fix the cause and repeat until it passes, then read the per-node plan it prints.
4. **Run the upgrade:**

   ```sh
   ansible-playbook -i inventory.ini upgrade.yaml
   # or, to confirm each node before the next one:
   ansible-playbook -i inventory.ini upgrade.yaml -e upgrade_pause_between_nodes=true
   ```

   Control planes go first, one at a time (kube-vip, `kubeadm upgrade`, then the node cycle). Then the `upgrade_shed` workloads are scaled down, the workers are cycled one at a time, and the shed workloads are restored. Expect roughly 10–20 minutes per node; most of it is draining and waiting for Longhorn rebuilds.
5. **Verify** (see [After every run](#after-every-run)), and also:

   ```sh
   kubectl get nodes -o wide        # VERSION and CONTAINER-RUNTIME match versions.yaml on every node
   ```

## OS maintenance (`maintenance.yaml`)

Installs all pending apt updates (`apt-get dist-upgrade`; the held kubernetes and containerd packages stay held) and reboots the nodes that need it, one node at a time, each one drained first. Use it for kernel updates, pending reboots (`/var/run/reboot-required`) and to catch up after unattended-upgrades has been off.

1. **Do the [checks before every run](#before-every-run).** The nodes must already be at the pinned kubelet/containerd versions; if not, run `upgrade.yaml` first.
2. **See what is pending** (read-only):

   ```sh
   for ip in 211 212 213 222 223; do
     printf '192.168.1.%s pending=%s reboot-required=%s\n' $ip \
       "$(ssh -i ~/.ssh/id_ed25519_ansible ansible@192.168.1.$ip 'apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c ^Inst')" \
       "$(ssh -i ~/.ssh/id_ed25519_ansible ansible@192.168.1.$ip 'test -f /var/run/reboot-required && echo yes || echo no')"
   done
   ```

3. **Preflight.** Changes nothing:

   ```sh
   ansible-playbook -i inventory.ini maintenance.yaml --tags preflight
   ```

4. **Run it.** Either all nodes in one go (control planes first, then workers):

   ```sh
   ansible-playbook -i inventory.ini maintenance.yaml
   ```

   or one node at a time, which is recommended after a long backlog or for a node with known problems. Wait for every Longhorn volume to be `healthy` between nodes, then run the next one:

   ```sh
   ansible-playbook -i inventory.ini maintenance.yaml --limit controlplane1
   ansible-playbook -i inventory.ini maintenance.yaml --limit controlplane2
   ansible-playbook -i inventory.ini maintenance.yaml --limit controlplane3
   ansible-playbook -i inventory.ini maintenance.yaml --limit worker2
   ansible-playbook -i inventory.ini maintenance.yaml --limit worker3
   ```

   With `--limit` on a worker, the playbook sheds and restores the `upgrade_shed` workloads within that run. It never sheds anything when only control planes are in the run. A node takes roughly 10–20 minutes. A large backlog with a reboot can take longer.

   Options:
   - `-e maintenance_apt_upgrade=false`: only reboot the nodes where a reboot is required, without installing anything.
   - `-e maintenance_reboot=always`: reboot every node in the run, even if no reboot is required.
   - `-e upgrade_pause_between_nodes=true`: ask for confirmation after each node.

5. **Verify** (see [After every run](#after-every-run)), and on each maintained node:

   ```sh
   ssh -i ~/.ssh/id_ed25519_ansible ansible@192.168.1.<ip> \
     'uname -r; sudo dpkg --audit | wc -l; test -f /var/run/reboot-required && echo reboot-required; networkctl status eth0 --no-pager --lines=0 | grep State:'
   ```

   Expect the new kernel, `0` from `dpkg --audit`, no `reboot-required`, and `routable (configured)`.

## After every run

```sh
kubectl get nodes                                   # all Ready, none SchedulingDisabled
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.status.kubernetesStatus.pvcName,STATE:.status.state,ROBUSTNESS:.status.robustness \
  | grep attached | grep -v healthy                 # empty (detached volumes always show "unknown")
kubectl get clusters.postgresql.cnpg.io -A          # all "Cluster in healthy state"
kubectl get hr -A | grep -v True                    # no failed or suspended HelmReleases
kubectl get deploy,sts,cronjob,clusters.postgresql.cnpg.io -A -o json \
  | jq -r '.items[] | select(.metadata.annotations["homelab.io/upgrade-restore"]) | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"'
                                                    # empty: every shed workload was restored
kubectl get pods -A | grep -vE 'Running|Completed'  # nothing stuck
```

Restored apps can take a few minutes to become ready again. wger's init containers, for example, wait for `wger-app`.

## When something goes wrong

| Situation | What to do |
|---|---|
| Preflight fails | Nothing has changed yet. Fix the reported cause and re-run. |
| Run fails or is aborted mid-way | Fix the cause and re-run the **same** command. A node left cordoned is drained and finished again. |
| You want the shed workloads back without finishing the run | `ansible-playbook -i inventory.ini upgrade.yaml --tags restore` (or `maintenance.yaml --tags restore`) |
| Keep workloads shed across several runs (upgrade.yaml) | `-e upgrade_restore=false`, then `--tags restore` at the end |
| Drain hangs | It times out after `upgrade_drain_timeout` (15m). Check which pod blocks it: `kubectl get pods -A -o wide --field-selector spec.nodeName=<node>`. The usual causes are PDBs and Longhorn volumes whose last replica is on the node. Then re-run. |
| Longhorn gate times out | `kubectl -n longhorn-system get volumes.longhorn.io` and the replicas of the degraded volume. Wait for the rebuild to finish and re-run. Never delete replicas to make the gate pass. |
| A node does not come back after reboot | It stays cordoned, so the cluster keeps running without it. Check it at the console. After it is back, re-run the same command. |

Timeouts and retries are set in [`group_vars/all/upgrade.yaml`](group_vars/all/upgrade.yaml).

## Unattended-upgrades

Unattended-upgrades installs security updates daily, one node per hour (controlplane1 at 03:00 … worker3 at 07:00), and never reboots. Reboots it leaves pending are done with `maintenance.yaml`. Missed runs are not caught up.

If the apt timers were stopped or masked for a while, the nodes build up a backlog. Unmask the timers only **after** running `maintenance.yaml` over all nodes, otherwise the backlog installs on live nodes:

```sh
ansible -i inventory.ini cluster -b -m shell -a 'systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer || true'   # "masked" = off
ansible -i inventory.ini cluster -b -m shell -a 'systemctl unmask apt-daily.timer apt-daily-upgrade.timer && systemctl enable --now apt-daily.timer apt-daily-upgrade.timer'
ansible -i inventory.ini cluster -b -m shell -a 'systemctl list-timers --no-pager apt-daily-upgrade.timer'        # next run at the node's slot
```

Masking leaves the repo's timer drop-ins in place. `cluster.yaml --tags unattended_upgrades` re-applies them if they are missing, and it never masks or unmasks the timers.
