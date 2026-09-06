# apps/box — GitOps manifest set for a dedicated-VM box

The complete on-box stack for the **dedicated Hetzner VM per customer**
substrate. Every box runs single-node k3s (Traefik + servicelb enabled) with
its own ArgoCD, which syncs this directory. One git tree serves the whole
fleet, but boxes do **not** track `master` — or any branch. Each box pins an
immutable commit and moves when its operator moves it; see
[Fleet rollout](#fleet-rollout) below.

**This tree is published**, because every box's ArgoCD must be able to pull it
without a credential — read [PUBLIC.md](./PUBLIC.md) first for what that means
for the comments here: they carry the reasoning behind the values, but they
name no internal file and no box.

## Fleet rollout

**A box declares the version it wants. This repository never pushes one.**
Every box's root `Application` (`box-root`) pins an **immutable commit**, and
nothing that happens in this tree — a merge, a tag, a branch — moves any box.
Publishing a version and deploying a version are separate acts with separate
operators.

That is a deliberate inversion of the earlier design, which had boxes follow a
moving "ring" branch here. A branch is a pointer inside the artifact, so
whoever can push to the artifact can move every follower; a box tracking it is
operated by this repository rather than by its owner. Pinning a commit removes
that entirely — and it removes the branch's real cause, too: `user_data` is
immutable after provisioning, so the ref baked at create time can never change,
and a moving branch was the only way such a pin could ever move at all.

**The interface is `box-root`, and it is the same one for everybody:**

| Field | Purpose |
|---|---|
| `spec.source.targetRevision` (+ the matching helm parameter) | which commit this box runs — upgrade *and* rollback |
| `spec.source.repoURL` (+ the matching helm parameter) | which tree it runs from — point it at a fork |

Both halves must move together: the root app is *self-managed* (it renders its
own definition from its own helm parameters), so editing only `spec.source.*`
lets the next render write the old value back. Edit both and the change is a
fixed point that reproduces itself, and the bootstrap-retire sentinels keep a
reboot from reverting it.

Per-box ArgoCD polls this repo (default ~3 min), so a pin change rolls a box
**without touching Terraform**.

### Two operators, one mechanism

**Self-hosted.** You are the operator. Pick a release, set the two fields, done
— and if you fork this tree, set `repoURL` too and carry your own patches.
Releases are tagged here with notes; a tag is a human index into history, not
something a box has to trust. Nothing about this path requires FairTier to
exist, be reachable, or agree.

**Managed.** FairTier's control plane keeps a desired commit per box and
answers when the box **asks** for it — the box authenticates outbound with its
own identity; nothing reaches inward. A small on-box agent compares that answer
to `box-root` and patches it. Staging is a set of boxes on a channel rather
than a branch topology: move the canary channel, verify, then move stable.
If the control plane is unreachable, the box keeps its pin and keeps running.

The property that matters for anyone leaving: **the managed path is one
component you can delete.** Remove the agent and no write path exists, because
none ever pointed inward. The box keeps running at its pin indefinitely, and
what remains is the self-hosted path above — the same fields, the same object,
nothing new to learn.

> **Status:** the pin is live and the agent ships in this tree
> ([box-release/](./box-release/)), gated **off** by `releaseAgentEnabled`
> until the control plane on the other end of it answers. With the gate off a
> box is exactly a self-hosted one: the pin moves by hand, by whoever operates
> the box.

**Rollback is the same write with an earlier commit** — nothing is destroyed,
git is the history. The caveat is not git but the payload: components that run
schema migrations are not safe to move backwards across a migration boundary,
so a release states whether it is downgrade-safe, and past that boundary the
honest lever is restore-from-backup, not a pin move.

**Stuck sync runbook** (hit live 2026-07-09): a crashlooping Sync-hook Job
pins its sync operation to the operation's original revision — retries
(`BeforeHookCreation`) recreate the hook from that OLD revision, so pushing
a fix does NOT reach the box while the operation runs, and the app can even
report `Synced` (hooks are excluded from the diff). Restarting the
application controller does not help (it resumes in-flight operations), and
`kubectl delete job` hangs on the `argocd.argoproj.io/hook-finalizer`
(deadlock: the controller waits on the job, the delete waits on the
controller). Recovery over ops SSH:

```bash
kubectl -n argocd patch application <app> --type json -p '[{"op":"remove","path":"/operation"}]'
kubectl -n fairtier-system patch job <hook-job> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
# wait for operationState.phase=Failed, then request a fresh sync at HEAD:
kubectl -n argocd patch application <app> --type merge -p '{"operation":{"initiatedBy":{"username":"ops-break-glass"},"sync":{"prune":true}}}'
```

**Why the pin has to be moved on the box, not in Terraform.** The ref reaches a
new box through cloud-init `user_data`, which is immutable after provisioning
(`ignore_changes`, because rewriting it would replace the server and the
customer's local state with it). So the provisioning-time value is
**create-only for the life of the box**, and every day-2 change — by an owner
or by the managed agent — is a write to `box-root`. That immutability is the
whole reason a moving branch existed; the fix is a day-2 write path, not a
mutable artifact.

Health feedback: each box's Alloy ships
`argocd_app_info` (sync/health per app, labeled `customer=<slug>`) to the
central Prometheus — see [Fleet telemetry](#fleet-telemetry-alloy--central).
"Did the rollout land everywhere" is a central Grafana query
(`argocd_app_info{fleet="box", sync_status!="Synced"}`), and the
`BoxArgoAppOutOfSync`/`BoxArgoAppUnhealthy` alerts
fire if a rollout leaves an app stuck for 30+ minutes.

## Bootstrap chain

cloud-init (authored in the provisioning Terraform, shared by all VM
substrates — **not** in this directory)
writes into `/var/lib/rancher/k3s/server/manifests/`:

1. a `HelmChart` CR installing **Argo CD** via the k3s built-in
   helm-controller — version pinned by cloud-init, matching the shared
   cluster (whose tracking pin carries its own caveat: read it before
   changing this one). **Bootstrap
   install only**: after the first sync the [argocd/](./argocd/) app adopts
   this CR, so day-2 upgrades come from the `argocdChartVersion` pin in
   [apps/values.yaml](./apps/values.yaml);
2. a repo `Secret` (a **read-only deploy token** for this repository — which
   a public tree no longer needs);
3. the root app-of-apps `Application` — the canonical copy is
   [root-app.yaml](./root-app.yaml); cloud-init templates `repoURL`,
   `targetRevision` and the per-customer helm parameters (`slug`,
   `baseDomain`, `acmeEmail`). After the first sync the root app is
   **self-managed** ([apps/templates/root-app.yaml](./apps/templates/root-app.yaml)),
   so day-2 spec changes converge too;
4. the per-customer `Secret`s/`ConfigMap`s in namespace `fairtier-system`
   (contract below) — deliberately **minimal**: only credentials the
   platform must know centrally. Everything else is generated on the box
   (see [Day-2 changes](#day-2-changes-what-converges-and-what-is-frozen)).

ArgoCD owns the charts *and* (via seed Jobs) the box-local secrets;
cloud-init owns only bootstrap identity and the centrally-known credentials.

**These files are bootstrap-only, and are retired once they have done their
job.** k3s applies `/var/lib/rancher/k3s/server/manifests` at *every* k3s
start, not just the first, so each of them would otherwise re-assert its
provisioning-day content over the GitOps twin at every reboot — a second
writer, running last, on a file no one can edit
([cloud-init drift](#cloud-init-drift)). [bootstrap-retire/](./bootstrap-retire/)
writes a k3s `.skip` sentinel beside each file once its twin is in place,
which stops k3s applying it and leaves everything it already created alone.

## App-of-apps layout

[root-app.yaml](./root-app.yaml) points at [apps/](./apps/), a small Helm
chart that templates one ArgoCD `Application` per component. Per-customer
values flow **root app helm parameters → app-of-apps chart → child
Application helm parameters** — that is the only supported, explicit
injection path; nothing reads config from the cluster at render time.

| App (sync wave)           | Source(s)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Namespace         |
|---------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------|
| `argocd` (0)              | [argocd/](./argocd/) (mini chart adopting the bootstrap `HelmChart` CR — day-2 ArgoCD upgrades; the release's **values** live in a [`HelmChartConfig`](./argocd/templates/helmchartconfig.yaml) so they outrank the frozen cloud-init copy, see [cloud-init drift](#cloud-init-drift))                                                                                                                                                                                                                                                                                                                                                                                                                                   | `kube-system`     |
| `box-root` (0)            | [apps/templates/root-app.yaml](./apps/templates/root-app.yaml) (self-managed root app, `Prune=false`)                                                                                                                                                                                                                                                                                                                                                                                                                             | `argocd`          |
| `cert-manager` (0)        | chart `jetstack/cert-manager` **v1.20.2** + [cert-manager/values.yaml](./cert-manager/values.yaml) + [cert-manager/issuers/](./cert-manager/issuers/) (mini chart: `letsencrypt-prod` ClusterIssuer)                                                                                                                                                                                                                                                                                                                              | `cert-manager`    |
| `postgres` (0)            | [postgres/](./postgres/) (kustomize, `postgres:17-alpine` StatefulSet + `postgres_exporter` v0.20.1 metrics sidecar on `:9187`, see [PostgreSQL metrics](#postgresql-metrics))                                                                                                                                                                                                                                                                                                                                                                                                                                                            | `fairtier-system` |
| `casdoor` (1)             | [casdoor/](./casdoor/) (mini chart, image `casbin/casdoor:3.153.0`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `fairtier-system` |
| `workspace-db` (1)        | [workspace-db/](./workspace-db/) (plain manifests, `migrate/migrate` Sync-hook Job) — schema of the box-local `workspace` database (created by the postgres ensure-databases Job): local-first run history for the dlt-worker on a box that has **not** been cut over, the box half of the control-plane/workspace-plane state inversion; migrations are additive-only and column-compatible with the central run tables. **Dead once `workspacePlaneLocal` is on** (Phase 3D): the worker then records runs straight into `workspace_api`, where the Console reads them, so this database stops being written and is kept only as the rollback target                                        | `fairtier-system` |
| `openfga` (1)             | [openfga/](./openfga/) (kustomize, image `openfga/openfga:v1.17.1`)                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `fairtier-system` |
| `lakekeeper` (2)          | chart `lakekeeper` **0.11.x** (image `v0.12.3`) + [lakekeeper/values.yaml](./lakekeeper/values.yaml) + [lakekeeper/ingress/](./lakekeeper/ingress/)                                                                                                                                                                                                                                                                                                                                                                               | `fairtier-system` |
| `duckflight` (2)          | OCI chart `ghcr.io/fairtier/charts/duckflight` **0.0.5** (image `0.1.0`; 0.0.5 = tag `helm/v0.0.5`, restricted-PSA securityContexts + no SA token by default) + [duckflight/values.yaml](./duckflight/values.yaml) + [duckflight/ingress/](./duckflight/ingress/)                                                                                                                                                                                                                                                                                                                                                     | `fairtier-system` |
| `gitea` (2)               | [gitea/](./gitea/) (mini chart, image `docker.gitea.com/gitea:1.26.4-rootless`) — hosted git for transformation repos                                                                                                                                                                                                                                                                                                                                                                                                             | `fairtier-system` |
| `rill` (2)                | [rill/](./rill/) (mini chart, image `rilldata/rill:v0.87.2` + oauth2-proxy `v7.15.3` + snapshot-sidecar `0.3.0` in git mode + `rill-deploy-shim` `0.0.1`, enabled — it fronts Rill and turns the Deploy button into a `TriggerSnapshot`) — the box BI tool; **two instances of the same project**: the editor (`rill.`) and a read-only `--preview` viewer (`dashboards.`), each with its own PVC + oauth2-proxy; project content synced with the on-box Gitea repo (see [Rill project git sync](#rill-project-git-sync))                                             | `fairtier-system` |
| `dlt` (2)                 | [dlt/](./dlt/) (mini chart, image `ghcr.io/fairtier/dlt-worker:0.15.0` + snapshot-sidecar `0.3.0` in git mode) — ingestion worker; schedules from the box `pipelines` checkout and decrypts `*.credentials.age` from it with the box age identity, writes Iceberg via the on-box Lakekeeper, state synced with the on-box Gitea repo (see [dlt state git sync](#dlt-state-git-sync)). Since the Phase 3C cutover `FAIRTIER_API_URL` points at the box's own `workspace-api:8081` — there is no phone-home, and since split Phase 4 nowhere else it could point. That poll is a **trigger feed**, not a config feed: Phase 2.5 shrank `GetPipelineConfigs` to Run-now triggers, `file_upload` storage credentials and the last-run watermark, and worker 0.9.0 requires the checkout (`PIPELINES_DIR`) | `fairtier-system` |
| `iceberg-maintenance` (2) | [iceberg-maintenance/](./iceberg-maintenance/) (mini chart, image `ghcr.io/fairtier/iceberg-maintenance:0.9.0`, which bakes pyiceberg `0.11.1`) — nightly CronJob: small-file compaction, snapshot expiry (7-day time-travel window) and an orphan-file sweep (Lakekeeper's maintenance task queues are enterprise-only, so the sweep is ours). The sweep runs in `dry-run` on every box whose `orphanSweepMaxDeletes` is 0 — a per-box helm parameter on that box's own `box-root` Application, and [apps/box/apps/values.yaml](./apps/values.yaml) records why it is deliberately not a slug-keyed value in this repo — so arming is **per box** and needs that box's own live-set proof first, which the `iceberg_maintenance.verify` module produces; auths as the `dlt-oidc` client                                                                                                       | `fairtier-system` |
| `box-secrets` (2)         | [box-secrets/](./box-secrets/) (mini chart, `alpine/k8s` Sync-hook Job + 15-minute CronJob) — the central→box credential channel: mints a box Casdoor token, calls `BoxCredentialService.FetchBoxSecrets`, and reconciles the answer into Kubernetes Secrets (into other namespaces too, where the consumer lives — the mapping in [box-secrets/values.yaml](./box-secrets/values.yaml) names one). **Wave 2 is a floor, not a preference**: it authenticates with the `dlt-oidc` client that casdoor seeds at wave 1, so nothing earlier can work and no consumer before wave 3 can read a box secret. A failed or 501 fetch leaves existing Secrets untouched — a central rollback must never blank a live credential | `fairtier-system` |
| `box-release` (2)         | [box-release/](./box-release/) (mini chart, `alpine/k8s` Sync-hook Job + CronJob) — **the deploy agent, and the whole of it**: mints a box Casdoor token, asks the control plane `release.v1.ReleaseService/GetBoxRevision`, and patches `box-root`'s `targetRevision` and its mirroring helm parameter when the answer differs. RBAC is `get`+`patch` on **one Application by name**, nothing else, and there is no `list`. A non-commit answer is refused rather than applied; an unreachable or silent control plane leaves the pin untouched. Gated off by `releaseAgentEnabled`. Deleting this Application removes every path by which anyone but the box's own operator can deploy to it — nothing else depends on it | `fairtier-system` |
| `workspace-api` (3)       | [workspace-api/](./workspace-api/) (mini chart, image `ghcr.io/fairtier/workspace-api:0.35.0` — the public [workspace plane](https://github.com/fairtier/workspace-api) the central FairTier API also imports as a Go module) — the product RPCs served **from the box**: box Postgres (`workspace_api` database, migrated by the binary) + box Gitea as source of truth, box Casdoor as the only trusted issuer, adopt + stuck-run sweeps in-process. The database starts empty and the adopt sweep **hydrates it from the box repos** (0.4.0+, `importFromRepo` lever): untracked `pipelines/*.yaml` / `transformations/*.yaml` are imported as rows keeping the ids the files carry, read-only toward the repos. Public mux published at `api.customer-<slug>.<baseDomain>`; the internal `:8081` (worker poll) is Service-only. **0.6.0 (Phase 3C)** is what lets a browser reach it: `GET /.well-known/fairtier-workspace` (unauthenticated — the Console cannot present a token before it learns which Casdoor to ask) advertises the box's issuer, org and `console` client id, and the seed Job mints that Casdoor app + Secret `console-oidc`; `AUTH_EXPECTED_AUDIENCES` then binds sessions to it so tokens minted for `rill`/`duckflight`/`dlt-worker` cannot reach the product RPCs (lever `enforceConsoleAudience`). Ships **shadow** until the per-customer cutover marker is set (split Phase 3C/3D); fleet lever `workspaceApiEnabled` in [apps/values.yaml](./apps/values.yaml)                                                                                            | `fairtier-system` |
| `backup` (3)              | [backup/](./backup/) (mini chart, `postgres:17-alpine` + `ghcr.io/rclone/rclone:1.74.4`) — nightly CronJob: pg_dump of every box database + tar of the Gitea PVCs → the customer's own bucket under `backups/`, 7-day retention (see [Backups](#backups))                                                                                                                                                                                                                                                                         | `fairtier-system` |
| `observability` (3)       | chart `grafana/alloy` **1.10.0** + [observability/values.yaml](./observability/values.yaml) + [observability/config/](./observability/config/) (mini chart: per-box River config + kubelet-metrics RBAC) — ships pod logs → central Loki (tenant = slug) and node/ArgoCD/cert-manager/cadvisor metrics → central Prometheus, outbound-only through `ingest.<baseDomain>` (see [Fleet telemetry](#fleet-telemetry-alloy--central)); local OTLP `:4317` receiver keeps DuckFlight's exporter target resolvable (traces dropped, v1). Behind `betterstack.enabled` (on since 2026-08-15) the same three signals also go **direct** to this box's own Better Stack source — a second remote_write endpoint, an `otelcol.receiver.loki` bridge for logs, and a real destination for traces instead of the blackhole; credentials arrive through `box-secrets`, never cloud-init. Additive only: the central push is untouched either way | `observability`   |
| `system-upgrade` (3)      | [system-upgrade/](./system-upgrade/) (vendored rancher/system-upgrade-controller **v0.19.2** manifests + the `k3s-server` Plan) — k3s day-2 upgrades: the Plan pins the fleet to `k3sVersion` in [apps/values.yaml](./apps/values.yaml); bumping the pin upgrades k3s through the normal GitOps rollout (cordon-only on the single node, no drain)                                                                                                                                                                                  | `system-upgrade`  |
| `bootstrap-retire` (3)    | [bootstrap-retire/](./bootstrap-retire/) (mini chart, `alpine/k8s` Sync-hook Job + daily CronJob) — writes a k3s `.skip` sentinel beside each cloud-init manifest whose GitOps twin exists, retiring the second writer that k3s's every-start re-apply creates ([cloud-init drift](#cloud-init-drift)); the only workload in `apps/box` with a read-write hostPath                                                                                                                                                              | `kube-system`     |
| `console` (4)             | [console/](./console/) (mini chart, image `ghcr.io/fairtier/console:0.13.0` — the public [workspace Console](https://github.com/fairtier/console), split out of the hosted Console) — the browser UI over `workspace-api`, served at `console.customer-<slug>.<baseDomain>`: a Bun static server + `/config.json` from `FT_*` env (all per-box values at runtime, the image ships neutral), PKCE against the box Casdoor `console` app (client id from Secret `console-oidc`; the redirect URI was pre-registered by the workspace-api seed Job). Wave 4: needs that Secret (wave 3) and is useless without workspace-api anyway. Fleet lever `consoleEnabled` in [apps/values.yaml](./apps/values.yaml)                                                                                            | `fairtier-system` |

All apps sync `automated` + `prune` + `selfHeal` with retries. Sync waves
order Application *creation*; real readiness ordering is handled inside the
components (wait-for-postgres init containers, migration jobs, ArgoCD
retries) — ArgoCD 3.x does not health-gate `Application` resources by
default.

Version pins and their sources are recorded in
[apps/values.yaml](./apps/values.yaml) (chart versions) and the component
values files (image tags). **Pin everything; no `:latest`.**

### Namespaces

A deliberate minimal set: the whole FairTier stack lives in
**`fairtier-system`** — the box is single-tenant, and this lets every
workload reference the cloud-init-written Secrets directly (`existingSecret`
never crosses namespaces). `argocd` (cloud-init), `cert-manager`, and
`observability` are separate.

### Resource requests: sizing rule

**A request on a box is a QoS decision, not a capacity plan.** The box is one
small node (3.7Gi / 2 vCPU on the cx-class boxes measured here), so a request
is a standing claim on headroom nothing else can use — while the thing it actually buys is the
container's `oom_score_adj`. No request at all means BestEffort, which the
kubelet stamps `1000`: the kernel's *first* pick under node-wide memory
pressure.

That default bit us. Until 2026-08-01 the box's largest memory consumer
(`argocd-application-controller`, ~221Mi measured) and its **ingress**
(Traefik) both requested nothing and ran BestEffort, while apps using a tenth
of their reservation — openfga 26Mi of 256Mi, casdoor 27Mi of 256Mi, rill
58Mi of 320Mi, duckflight 127Mi of 512Mi — sat protected in Burstable. So
under pressure the kernel reliably killed GitOps and the ingress and spared
the idle workloads, which is how "OOM cascade freezes GitOps sync" happens.
Restart counters told the story: 112 on argocd-repo-server, 110 on
argocd-server.

Three rules keep this from regressing:

1. **Size requests from measured usage over time**, not round numbers and not
   a single sample. Round numbers are how 256Mi ends up reserved for a 26Mi
   process. The one direction this cuts both ways: a request *below* measured
   usage is not a saving either (Alloy was at 195Mi against a 128Mi request —
   an eviction candidate that would take the box's telemetry with it).

   Use the **central** Prometheus, not `kubectl top`. The box ships
   `container_memory_working_set_bytes` (it is on the Alloy keep-list), so
   there is a seven-day history per container:

   ```promql
   quantile_over_time(0.95, container_memory_working_set_bytes{fleet="box",customer="<slug>",container!=""}[7d])
   max_over_time(container_memory_working_set_bytes{fleet="box",customer="<slug>",container!=""}[7d])
   ```

   `kubectl top` returns whatever the container happens to hold at that
   second, and on a box most containers are idle most of the time. Every
   request on this box was originally set from one such sample, and the
   2026-08-13 re-derivation ([below](#the-2026-08-13-re-derivation)) found
   them wrong in *both* directions — repo-server reserved 64Mi against a
   112Mi p95, duckflight reserved 128Mi against an 80Mi weekly maximum.
   Do not read the cgroup's `memory.peak` either: it counts reclaimable page
   cache, so it overstates a quiet container by 3-4× (rill-0 showed a 290Mi
   peak against a 79Mi p95 working set).
2. **Keep changes net-neutral or better.** Total requests must leave room for
   the nightly `iceberg-maintenance` CronJob (256Mi / 100m) *plus* the other
   Jobs, or table maintenance silently stops scheduling — a failure that
   surfaces as slow queries weeks later, not as an error. Before the
   rebalance there was 601Mi/190m spare, i.e. less than one CronJob on CPU;
   after it, 1001Mi/405m.
3. **Fit *allocatable*, not capacity.** Since 2026-08-10 the kubelet reserves
   memory for k3s and the OS and evicts before the node thrashes
   ([node memory floor](#node-memory-floor)), so a 3.7Gi box offers ~2.8Gi to
   pods, not 3.7Gi. Requests above that don't fail loudly — pods stay
   Running and only the *next* restart lands in `Pending`. Check with
   `kubectl describe node` (Allocatable vs the Allocated-resources total),
   not with `free`.

<a id="the-2026-08-13-re-derivation"></a>
#### The 2026-08-13 re-derivation, and the wall it hit

Every request above was re-derived from seven days of working set. The
headline was supposed to be "trim the over-reservers and free ~330Mi". That
premise was wrong, and the measurement is the finding.

There is no 330Mi of fat. Total harvestable slack — every container whose
request exceeded its *weekly maximum* — is **98Mi**:

| container | was | 7d p95 | 7d max | now |
|---|---|---|---|---|
| duckflight | 128Mi | 80Mi | 80Mi | 96Mi |
| alloy `config-reloader` | 50Mi (chart default) | 12Mi | 18Mi | 24Mi |
| argocd `redis` | 32Mi | 9Mi | 10Mi | 16Mi |
| rill `snapshot` ×2 | 32Mi | 16 / 19Mi | 18 / 20Mi | 24Mi |
| `postgres-exporter` | 32Mi | 16Mi | 20Mi | 24Mi |

Meanwhile five containers sit *below* their own request — the eviction-
candidate condition — and correcting all five costs **192Mi**, more than the
slack pays for. Two were funded here, chosen by blast radius:

| container | was | 7d p95 | 7d max | now |
|---|---|---|---|---|
| `postgresql` | 192Mi | 222Mi | 235Mi | **240Mi** |
| argocd `repo-server` | 64Mi | 112Mi | 175Mi | **128Mi** |

Three could not be, and are the standing debt: argocd
`application-controller` (256Mi vs 272Mi p95, +32Mi wanted), `alloy` (192Mi vs
202Mi, +32Mi), rill-viewer `rill` (96Mi vs 100Mi, +16Mi) — and the big one,
`iceberg-maintenance` at 256Mi against a **447Mi p95** across three nightlies,
which wants +256Mi.

Net effect of this pass: −98Mi trimmed, +112Mi paid, so requests move
2414Mi → **2428Mi** (85% of the 2852Mi allocatable), and 2684Mi (94%) while
the nightly runs. That leaves **168Mi** spare during the nightly against
**336Mi** of remaining honest demand.

So the box is ~170Mi short of being able to tell the truth in every request,
and no further trimming closes it — the slack is spent. The two real options
are to grow the node, or to shed a component; the largest discretionary claim
is the read-only `rill-viewer` StatefulSet at 144Mi of request (`rill` 96 +
`snapshot` 24 + `oauth2-proxy` 24) plus its own 1Gi limit. Both are decisions,
not fixes, and neither is taken here.

<a id="node-memory-floor"></a>
#### The node memory floor

k3s ships the kubelet with **no memory eviction signal** — its `evictionHard`
is `{imagefs.available: 5%, nodefs.available: 5%}`, disk only, replacing the
upstream `memory.available<100Mi` default — and reserves nothing for itself
or the OS. Read together with the rule above: allocatable equalled capacity,
so requests could promise memory k3s (1.3Gi of a 3.7Gi box, unbounded in
`system.slice`) was already using, and when the box ran out the kubelet
evicted *nothing*. It went to reclaim thrash instead, which is what killed
CoreDNS on 2026-08-10 — by liveness-probe timeout under CPU starvation
(exit 0), not by the OOM killer, so neither a priority class nor a memory
limit would have saved it.

The floor lives in `/etc/rancher/k3s/config.yaml`, written by
cloud-init on new boxes and applied out of band on existing ones
([migration](#legacy-box-migration-node-memory-floor)): `system-reserved`
128Mi, `kube-reserved` 640Mi, `eviction-hard` at `memory.available<200Mi`
(with k3s's disk thresholds restated, because that flag *replaces* the map
rather than merging into it). `kube-reserved` is deliberately below k3s's
measured footprint: it is a floor for the control plane, not an accounting of
it.

Limits follow the opposite logic and mostly stayed put: they bound a
runaway's blast radius and cost nothing while unused. The exception is
anything on the critical path for surviving pressure — ArgoCD and Traefik are
deliberately **requests-only**, because a limit there converts node pressure
into a memcg kill of the component that has to survive it.

Where they live: [argocd](./argocd/templates/helmchartconfig.yaml) (a
`HelmChartConfig`, so the frozen cloud-init copy of the `HelmChart` cannot
revert them — [cloud-init drift](#cloud-init-drift)),
[traefik](./traefik/) (also a `HelmChartConfig`,
since k3s owns that release), and each app's own `values.yaml` /
`deployment.yaml`. Note [lakekeeper](./lakekeeper/values.yaml): its block
must sit under `catalog:`, because that chart nests the catalog Deployment's
settings there and silently ignores a top-level `resources:` — it sat
top-level from the first commit, so the file claimed 256Mi while the
container ran with none.

#### Every container with no memory limit, and why (2026-08-13)

"No limit" reads the same in a manifest whether it was chosen or forgotten,
and this list was carried for two days as *"14 containers carry no memory
limit — deliberate for ArgoCD/Traefik, unreviewed for the rest, and the two
currently look identical"*. Reviewing it: the count is **12**, and after this
pass exactly one needed changing. Kept here so the next audit starts from the
reasons rather than the count.

| container(s) | reason it has no limit |
|---|---|
| `argocd` × 5 (application-controller, repo-server, server, applicationset, redis) | **Deliberate.** A limit on the component that must survive node pressure converts a node-wide kill into a memcg kill — the same outage with a different label. Also the one set that *cannot* have `system-node-critical` (the Priority admission plugin restricts it to `kube-system`, and ArgoCD is in `argocd`), so requests are its only lever. |
| `traefik` | **Deliberate**, same argument — it is the ingress. Since 2026-08-12 it also carries `system-node-critical`, so it sits at `oom_score_adj` -997 and the limit question is close to moot. |
| `svclb-traefik` × 2, `local-path-provisioner` | **Not ours, and not at risk.** Built by k3s controllers with empty `resources` and no ownerRefs. Both run `system-node-critical` ⇒ -997, i.e. the two best-protected containers on the box. Tracked for weeks as unfixable gaps; they were never gaps. |
| `metrics-server` | k3s packaged, also `system-node-critical` ⇒ -997. Bounding it needs the `.skip` + owned-copy route, for a container that is last in line anyway. |
| `system-upgrade-controller` | **Deliberate** (2026-08-12, chart 0.2.0). Requests-only on purpose: its 82MB peak lands mid-k3s-upgrade, and a memcg kill *there* is worse than 82MB briefly unbounded. |
| `alloy` config-reloader | **Was the only genuine oversight. Bounded 2026-08-13** at 64Mi (3.5× its 18Mi weekly max). The ArgoCD/Traefik argument does not transfer: killing the config reloader costs nothing — Alloy keeps running on the config it already loaded and the sidecar restarts — so here a limit is pure upside. |

The general shape: **"unbounded" is only a defect when a memcg kill would be
cheaper than the node-wide kill it prevents.** For everything on the
survive-the-pressure path it is the opposite, and for a node-critical pod it
barely matters either way.

On the total: measured at the end of this pass the box is at **9578Mi of
limits against 2852Mi allocatable — 335%**, not the 347% carried in earlier
notes. The figure moves with whatever is scheduled at the time (the nightly
maintenance Job alone is 1Gi), so quote it with a date or not at all.

Either way it is not itself alarming: limits bound blast radius, cost nothing
unused, and the node cannot hand out more than it has. It does mean the box
relies on nothing reaching its limit at once — and what bounds *that* is the
request total ([the re-derivation](#the-2026-08-13-re-derivation)), not the
limit total.

## Hostnames & TLS

Scheme: `<service>.customer-<slug>.<baseDomain>` (matches the shared
substrate, so `ActualConfig` URLs are shape-identical). DNS is a wildcard A
record `*.customer-<slug>.<baseDomain>` → VM IPv4, managed by Terraform
(Phase 2).

- `auth.customer-<slug>.<baseDomain>` → Casdoor (Ingress, class `traefik`)
- `lakekeeper.customer-<slug>.<baseDomain>` → Lakekeeper `:8181` (Ingress)
- `duckflight.customer-<slug>.<baseDomain>` → DuckFlight `:31337`
  (Traefik `IngressRoute`, `scheme: h2c` — gRPC behind TLS termination)
- `git.customer-<slug>.<baseDomain>` → Gitea `:3000` (Ingress; HTTPS-only,
  SSH disabled — git over HTTPS with tokens)
- `rill.customer-<slug>.<baseDomain>` → oauth2-proxy `:4180` → Rill `:9009`
  (Ingress; Rill's local mode has no auth of its own, so the Ingress backend
  is always the oauth2-proxy — Casdoor OIDC, the Traefik-world replacement
  for the shared path's Envoy SecurityPolicy)
- `dashboards.customer-<slug>.<baseDomain>` → viewer oauth2-proxy `:4180` →
  Rill viewer `:9009` (Ingress; the read-only `rill start --preview`
  instance — same Casdoor `rill` client, second redirect URI registered by
  the seed Job)
- `console.customer-<slug>.<baseDomain>` → workspace Console `:3000`
  (Ingress; static SPA + `/config.json`, no auth of its own — the login it
  starts is the box Casdoor's)
- `api.customer-<slug>.<baseDomain>` → workspace API `:8080` (Ingress;
  the box's own product API — Connect over HTTP/1.1, box Casdoor JWT. Its
  internal `:8081` mux, which serves the worker poll and its source
  credentials, is **deliberately not published**)
- `rill-snapshot.customer-<slug>.<baseDomain>` → editor snapshot sidecar
  `:8484` (Traefik `IngressRoute`, `scheme: h2c`; bearer-gated by the
  sidecar's `AUTH_TOKEN` — minted by the seed Job and presented by the
  box's own workspace-api when the Console Save button triggers an
  on-demand publish; central held a deposited copy until split Phase 3E)

TLS: cert-manager, **HTTP-01 via Traefik**, ClusterIssuer
[`letsencrypt-prod`](./cert-manager/issuers/templates/clusterissuer-letsencrypt-prod.yaml),
one certificate per hostname (ingress-shim annotation for the two Ingresses,
an explicit `Certificate` for the IngressRoute). Deliberately **no wildcard
DNS-01** — a wildcard would need a DNS-provider API token on every box, and
the point of HTTP-01 here is that no such token exists to leak.

## cloud-init secret/config contract (`fairtier-system`)

No secret is ever committed to git. The manifests reference these by fixed
name; cloud-init must create them **before** the root app syncs. The set is
deliberately minimal — **only credentials the platform must know centrally**
(worker automation / Console display) plus the postgres superuser DSNs
derived from it:

> **This table is closed to new entries.** Everything here is bootstrap
> identity — needed before anything on the box can run, therefore before
> anything can fetch. A credential that does not meet that bar goes through
> [box-secrets/](./box-secrets/) instead, because a value delivered here is
> frozen for the life of the machine: `user_data` is create-only on hcloud, so
> the provisioning Terraform pins it with `ignore_changes` to stop a template
> edit destroying a customer's box.

| Object                                                                                                                                                                   | Keys                                                                                                                                                                                                                                                 | Consumed by                                                                                    |
|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| Secret `postgres-credentials`                                                                                                                                            | `postgres-password` (superuser)                                                                                                                                                                                                                      | [postgres/statefulset.yaml](./postgres/statefulset.yaml)                                       |
| Secret `casdoor-conf`                                                                                                                                                    | `dataSourceName` (full beego DSN incl. password, `dbname=casdoor`)                                                                                                                                                                                   | [casdoor deployment](./casdoor/templates/deployment.yaml) (env override of `app.conf`)         |
| Secret `openfga-postgres`                                                                                                                                                | `datastore-uri` (postgres URI incl. password, db `openfga`)                                                                                                                                                                                          | [openfga](./openfga/)                                                                          |
| Secret `lakekeeper-postgres`                                                                                                                                             | `postgres-user`, `postgres-password`                                                                                                                                                                                                                 | [lakekeeper/values.yaml](./lakekeeper/values.yaml)                                             |
| Secret `lakekeeper-secrets`                                                                                                                                              | `encryption-key`                                                                                                                                                                                                                                     | [lakekeeper/values.yaml](./lakekeeper/values.yaml)                                             |
| Secret `lakekeeper-oidc`                                                                                                                                                 | `client-id`, `client-secret` — **the** centrally-known Casdoor client: the worker authenticates to Lakekeeper with it, the Console shows it to the customer                                                                                          | [casdoor seed Job](./casdoor/templates/seed-job.yaml) (seeds the matching Casdoor application) |
| Secret `duckflight-auth-secrets`                                                                                                                                         | `auth-tokens`, `auth-users`, `basic-username`, `basic-password` (token surfaced in the Console)                                                                                                                                                      | [duckflight/values.yaml](./duckflight/values.yaml)                                             |
| ConfigMap `box-config`                                                                                                                                                   | `slug`, `baseDomain` (informational — the authoritative injection is the root-app parameters)                                                                                                                                                        | humans / future agent                                                                          |
| ConfigMap `fairtier-customer`                                                                                                                                            | `customerSlug`, `customerName`, `customerDomain`, `baseDomain` (informational, non-secret)                                                                                                                                                           | humans / future agent                                                                          |
| Secret `fairtier-storage`                                                                                                                                                | `s3*` (bucket-scoped, **consumed on the box** — see [R2 credentials](#r2-credentials) below), `cloudflareAccountId`, `cloudflareApiToken` (**no on-box consumer**)                                                                                    | dlt-worker, iceberg-maintenance, backup                                                        |
| Secret `alloy-ingest-auth` (**ns `observability`** — the one contract object outside `fairtier-system`: Alloy runs there and Secrets can't be mounted across namespaces) | `username` (= slug), `password` — fleet telemetry ingest credential (sent as basic auth); the matching API-key entry is aggregated centrally on every worker apply | [observability/values.yaml](./observability/values.yaml) (mounted at `/etc/alloy-ingest`)      |

Key names mirror the frozen shared-cluster path, so the worker-side
lifecycle code keeps one mental model.

**Contract amendment, 2026-07-17:** `alloy-ingest-auth` was added for the
Phase-5 fleet telemetry. It passes the "centrally needed" test (the central
gateway must know the same credential), so it belongs in the Terraform seed
rather than an on-box seed Job — but since cloud-init never re-runs, boxes
provisioned before the amendment must receive it once by hand
([Legacy-box migration](#legacy-box-migration-alloy-ingest-auth)).

Everything else in `fairtier-system` is **generated on the box** by seed
Jobs and never passes through Terraform:

- [casdoor seed](./casdoor/templates/seed-job.yaml) — `casdoor-init-data`,
  `casdoor-admin-credentials`, `casdoor-builtin-admin` (the rotated password
  for Casdoor's stock `built-in/admin` bootstrap account — the seed disables
  the well-known `123` default over the public admin UI), `web-oidc`,
  `duckflight-iceberg-secrets`, `rill-iceberg-secrets`, `dlt-oidc`,
  `lakekeeper-audiences`
- [gitea seed](./gitea/templates/seed-job.yaml) — `gitea-secrets`
- [rill seed](./rill/templates/seed-job.yaml) — `rill-oidc`, `rill-git`
  (Gitea access token for the snapshot sidecar), `rill-snapshot-auth`,
  `platform-git`
- [dlt seed](./dlt/templates/seed-job.yaml) — `dlt-git`, `dlt-age` (the box
  age identity for pipeline credential files — neither half leaves the box
  since split Phase 3E retired the public-key deposit), `pipelines-git`,
  `transformations-git`
- [workspace-api seed](./workspace-api/templates/seed-job.yaml) —
  `workspace-api-crypto` (the box-only at-rest key; **no central copy
  exists**), `console-oidc`

Boxes
provisioned before this scheme got some of those from cloud-init; the seeds
adopt them (extract → materialize per-app Secrets), so old and new boxes
converge to the identical state.

<a id="r2-credentials"></a>
**R2 credentials** (Secret `fairtier-storage`): warehouse creation
(including pushing R2 credentials into Lakekeeper) is done by the
FairTier API's worker over the public Lakekeeper URL, same as on the shared
path. On the box the Secret has three direct consumers — the
[dlt-worker](./dlt/templates/statefulset.yaml), whose dlt filesystem
destination writes Iceberg data files straight to the bucket, the
[iceberg-maintenance CronJob](./iceberg-maintenance/templates/cronjob.yaml)
(direct data-file IO during compaction), and the
[backup CronJob](./backup/templates/cronjob.yaml) (uploads nightly dumps to
`backups/` — the static bucket-scoped credentials are the only ones that
can write outside the warehouse prefix).

The `cloudflareApiToken` key is different and worth calling out: **nothing on
the box reads it** (repo-wide it appears only in the cloud-init template), and
it carries an **account-scoped** R2 policy on top of the bucket-scoped one,
because R2's
temp-access-credentials endpoint that Lakekeeper's vending calls cannot be
confined to one bucket. Deleting the key here would not remove the exposure on
its own — with `credential_delegation_mode = vended` the same token is stored
inside the box Lakekeeper's warehouse storage profile — so the two move
together, after a decision on whether boxes vend at all.

Databases `casdoor`, `openfga`, `lakekeeper`, `gitea` are converged on
every sync by the idempotent
[postgres/ensure-databases-job.yaml](./postgres/ensure-databases-job.yaml)
(day-2 safe — adding a database reaches existing boxes on their next pin
move); the DSNs above may use the `postgres` superuser (MVP) or
per-service users — that choice lives in cloud-init, not here.

## Day-2 changes (what converges, and what is frozen)

A box's cloud-init runs **exactly once** (`user_data` is immutable,
`ignore_changes`), so anything delivered only by cloud-init is fixed at
provision time. **A new feature must never require re-provisioning a box**
— and after the seed-Job rework, nothing feature-shaped is left in
cloud-init.

Since 2026-08-15 that holds for **centrally-minted secrets** too, which were
the last category with no day-2 path: [box-secrets/](./box-secrets/) fetches
them from central on a schedule. If you are about to add a key to the
[cloud-init contract](#cloud-init-secretconfig-contract-fairtier-system),
you almost certainly want that chart instead — the contract is for bootstrap
identity, and a value that lands there can never be corrected or rotated
without replacing the customer's machine.

Worse than fixed, until [bootstrap-retire/](./bootstrap-retire/): what
cloud-init writes into the k3s auto-deploy directory was re-asserted at
every k3s start, so a day-2 change to one of those objects reverted at the
next reboot rather than merely being absent from new boxes. Read
[cloud-init drift](#cloud-init-drift) before assuming any row below survives
a reboot on a box provisioned before 2026-08-11.

The full audit of every create-time-baked aspect:

| Aspect                                                                                     | Day-2 path                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
|--------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| App manifests, config, image/chart pins                                                    | pin-move rollout (GitOps) — the normal path                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| New **databases**                                                                          | [postgres/ensure-databases-job.yaml](./postgres/ensure-databases-job.yaml), converges every sync                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| New **box-local credentials**                                                              | idempotent seed Job: create-Secret-if-absent (+ Casdoor app via management API where needed). Pattern: [gitea/templates/seed-job.yaml](./gitea/templates/seed-job.yaml) + [seed-rbac.yaml](./gitea/templates/seed-rbac.yaml) (negative sync waves: RBAC → seed → consumers)                                                                                                                                                                                                                                                                                   |
| **Casdoor identity seed** (org, applications, admin user, JWT cert)                        | rendered on the box by [casdoor/templates/seed-job.yaml](./casdoor/templates/seed-job.yaml) from [casdoor/values.yaml](./casdoor/values.yaml) `initDataApplications`; `initDataNewOnly = true` makes Casdoor apply it create-if-absent, and the JWT signing key is generated by Casdoor itself (never in Terraform state). Editing the seeded shape = fleet rollout                                                                                                                                                                                           |
| **ArgoCD version**                                                                         | [argocd/](./argocd/) adopts the bootstrap `HelmChart` CR; bump `argocdChartVersion` in [apps/values.yaml](./apps/values.yaml). Reverted at every k3s start until the box's cloud-init manifest is retired ([bootstrap-retire/](./bootstrap-retire/)) — `version` is the one thing the `HelmChartConfig` cannot outrank                                                                                                                                                                                                                                        |
| **ArgoCD values** (QoS requests, probes, params)                                           | [argocd/templates/helmchartconfig.yaml](./argocd/templates/helmchartconfig.yaml) — merged over the frozen cloud-init `HelmChart`, so this one converges on legacy boxes without waiting for retirement                                                                                                                                                                                                                                                                                                                                                        |
| **Root app spec** (syncPolicy, new fleet-wide parameters)                                  | self-managed [apps/templates/root-app.yaml](./apps/templates/root-app.yaml)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Ring branch** of a box, **repo deploy token**, values of the **contract Secrets**        | edit in-cluster (ops break-glass) — sticks only once [bootstrap-retire/](./bootstrap-retire/) has written the sentinel for that box, otherwise the next reboot restores the provisioning-day value                                                                                                                                                                                                                                                                                                                                                            |
| **k3s version**                                                                            | [system-upgrade/](./system-upgrade/): bump `k3sVersion` in [apps/values.yaml](./apps/values.yaml) (the cloud-init `var.k3s_version` install pin only matters at first boot — keep the two moving together)                                                                                                                                                                                                                                                                                                                                                    |
| **OVH host firewall / ops IP allowlist**                                                   | 📋 planned: GitOps-managed nftables; the bootstrap ruleset is a safe default-drop. Hetzner uses the mutable `hcloud_firewall` (already day-2)                                                                                                                                                                                                                                                                                                                                                                                                      |
| Credentials the **platform must know centrally** (incl. rotation of existing values)       | **[box-secrets/](./box-secrets/)** — the generic central→box channel, built 2026-08-15. Add the value to the central `box_secrets` output and a mapping entry in [box-secrets/values.yaml](./box-secrets/values.yaml); the reconciler stores it (`publishBoxSecrets`) and the box fetches it with a box-Casdoor token (`BoxCredentialService.FetchBoxSecrets`) every 15 min and on every sync. **Never a new cloud-init secret** — the previous amendment (`alloy-ingest-auth`, 2026-07-17) cost a [one-time migration](#legacy-box-migration-alloy-ingest-auth) for the legacy box, which is exactly what this row now avoids. The deposit direction (box→central) still exists but is down to **one** RPC since split Phase 3E: `DepositFederationClient`. The git token, snapshot bearer and age public key are no longer deposited — a box writes its own repos, so central holding a copy bought nothing. Deposit is still the right shape for anything the box mints that *central* genuinely needs |
| **Bootstrap identity**: slug/domain, the create-time revision pin, repo deploy token, cloud-init itself | frozen by design; changing them is ops break-glass over SSH, and now *stays* changed once the manifest is retired (row above). SSH key changes replace the server — the one accepted recreate                                                                                                                                                                                                                                                                                                                                                                                          |

## Rill project git sync

The customer-authored Rill content (dashboards, models) lives in the on-box
Gitea repo **`fairtier-admin/rill`** (private; created by the
[rill seed](./rill/templates/seed-job.yaml), which also mints the sidecar's
scoped access token into Secret `rill-git`). The rill pod runs
[snapshot-sidecar](https://github.com/fairtier/snapshot-sidecar) in **git
mode** — the same binary the frozen shared path runs in S3 mode:

- **restore** (init container, before the ConfigMap overlay): open the clone
  on the PVC, or adopt it on first boot — local files are never overwritten.
- **save** (`AUTOSAVE_INTERVAL`, TriggerSnapshot on `rill-snapshot:8484`,
  SIGTERM): commit the dirty tree + plain push.
- **sync** (`SYNC_INTERVAL`): fast-forward pull, only when the tree is clean
  with nothing unpushed; Rill's file watcher hot-reloads pulled files.

Platform-managed files (`rill.yaml`, `duckdb.yaml`, `.env`) are gitignored in
the repo and keep coming from the ConfigMap overlay — editing them in Gitea
has no effect (and connector changes still roll the pod via the checksum
annotation).

**The viewer instance** (`rill-viewer`, serving `dashboards.customer-<slug>`)
is a second StatefulSet over the same repo running `rill start --preview` —
Rill's mode is fixed at startup and two processes can't share one project dir
(embedded DuckDB), so it has its own PVC. Its sidecar is pull-only: same
restore + sync (ff-pull → hot-reload) on a short 15s interval, autosave
disabled (`--preview` authors nothing non-ignored — the editor instance is
the sole writer).

**Publishing.** Two channels move editor state to `dashboards.`:

- *Background*: editor autosave (≤5 min) → Gitea → viewer sync (≤15 s).
- *On demand — the Console Save button*: Console → the box's workspace-api
  `SnapshotService.TriggerSnapshot` → the box's published
  `rill-snapshot.customer-<slug>` endpoint (bearer read locally from the
  `rill-snapshot-auth` Secret) → sidecar commits + pushes immediately →
  viewer sync (≤15 s). End-to-end a Save is live on `dashboards.` in
  ~15–20 s (plus model re-run time if the change touches sources/models).

**Known limitation — Rill Developer's native cloud UI.** The editor is Rill
*Developer* (`rill start`, local mode, no auth of its own — auth is entirely
the oauth2-proxy in front). Its built-in **Deploy** button and account
**logout** both target Rill's own localhost runtime
(`http://localhost:9009/auth?redirect=…`), assuming a Rill Cloud handshake
that does not exist in our hosted, self-hosted-viewer architecture — so from
a browser they dead-end. They are **not** our publish/logout paths:

- *Deploy* → use the **Console Save** button (Apps → Rill), which drives the
  snapshot sidecar → Gitea → `dashboards.` (the Publishing flow above). Rill's
  own Deploy is a no-op here.
- *Logout* → the real session gate is the oauth2-proxy cookie; hit
  `https://rill.customer-<slug>.<baseDomain>/oauth2/sign_out` (and the same on
  `dashboards.`) to clear it. Rill's own logout button can't reach
  `localhost:9009` from the browser.

Rill Developer exposes no flag to hide this cloud chrome, so the buttons
remain visible but inert; a UI-level suppression (proxy-injected CSS/redirect)
is a possible later workaround. Contrast Gitea, whose analogous broken
logout redirect **is** fixed at the ingress
([casdoor/templates/middleware-gitea-logout.yaml](./casdoor/templates/middleware-gitea-logout.yaml)).

**Conflicts — never force, never auto-merge.** A save whose push is rejected
returns status `remote_changed` and keeps the commit local; the sync loop
refuses to pull over local changes. Check
`GET rill-snapshot:8484/debug/sync-status` — the local commit shows as
`state: ahead` (head ≠ remoteHead; drilled live 2026-07-12). To resolve on
the single-node box (RWO PVC co-mounts fine):

```bash
kubectl -n fairtier-system run rill-git-fix --rm -it --restart=Never \
  --image=alpine/git --overrides='{"spec":{"containers":[{"name":"rill-git-fix",
  "image":"alpine/git","stdin":true,"tty":true,"command":["sh"],
  "volumeMounts":[{"name":"project","mountPath":"/project"}]}],
  "volumes":[{"name":"project","persistentVolumeClaim":{"claimName":"project-rill-0"}}]}}'
# inside (the PVC is owned by the rill UID, so git needs safe.directory):
#   git config --global --add safe.directory /project
#   cd /project && git pull --rebase && git push   (token from Secret rill-git)
kubectl -n fairtier-system delete pod rill-0   # REQUIRED after any out-of-band
# git surgery: the sidecar's long-lived go-git handle caches refs/packfiles
# and every save fails with "object not found" / missing-pack errors until
# the pod restarts (hit live in the 2026-07-12 drill).
```

Alternatively make the remote fast-forwardable (reset the branch in Gitea)
and trigger another save — a repeated save retries the push.

## dlt state git sync

dlt's execution state lives in the on-box Gitea repo **`fairtier-admin/dlt`**
(private; created by the [dlt seed](./dlt/templates/seed-job.yaml), which
also mints the sidecar's scoped access token into Secret `dlt-git`). Same
mechanism as the [Rill sync](#rill-project-git-sync) — the dlt pod runs
[snapshot-sidecar](https://github.com/fairtier/snapshot-sidecar) in **git
mode** — but the content is different in kind: the repo holds **machine-owned
state**, not customer-authored files. Committed: per-pipeline `state.json`
(incremental cursors) and `schemas/` (inferred table schemas) — settled
after every run, but only *changed* when data actually moves, so a
no-new-data run produces no commit.
Gitignored (seeded `.gitignore`): `trace.pickle`, `load/`, `normalize/`,
`tmp/` — the run artifacts that stage extracted data on the PVC — plus
`scheduler.json`, the worker-owned files-mode `last_run_at` map. It is
PVC-only on purpose: it gets a timestamp bump on **every** successful run,
so committing it produced a valueless per-run snapshot commit (a bare
timestamp diff). Losing it on a fresh-box/disk-loss restore is benign — at
most one extra run per pipeline, deduped by the committed cursors. Reset a
cursor break-glass via `state.json` (still committed), not `scheduler.json`.

Pipeline *definitions* are not in this repo — they live in the separate
**`fairtier-admin/pipelines`** repo. The Console
edits them in central Postgres and mirrors every save into that repo; the
dlt pod keeps a **pull-only** checkout of it (emptyDir, `pipelines-restore`
init container + `pipelines-sync` sidecar with autosave disabled — nothing
on the box ever commits there) and the worker schedules from the files
(`PIPELINES_DIR`, dlt-worker ≥0.1.0).

Source credentials are files in that repo too (Phase 3, dlt-worker ≥0.2.0):
central renders `pipelines/<name>.credentials.age` — **armored age
ciphertext**, encrypted to the box's public key — beside each definition,
and the worker decrypts them with the box age identity (Secret `dlt-age`,
mounted read-only at `/age`, `AGE_KEY_FILE`). The keypair is generated on
the box by [dlt-seed](./dlt/templates/seed-job.yaml) step 4 (agekey init
container running the worker image); neither half leaves the box — the box's
own workspace-api reads the public half from the same Secret and does the
rendering. Central held a deposited copy of the public key until split Phase
3E retired `BoxCredentialService/DepositAgePublicKey`.
File-decrypted credentials win over the poll, so a pipeline with a
credential file runs through a central outage even from a fresh pod.

The worker still polls
`https://worker-api.<baseDomain>/pipeline.v1.PipelineService/…` every tick —
now only for Run-now triggers, plus source credentials as a fallback for
pipelines without a credential file — with a client-credentials token from
the on-box Casdoor (Secret `dlt-oidc`, seeded by
[casdoor-seed](./casdoor/templates/seed-job.yaml)). The FairTier API trusts
the box's issuer (`auth.customer-<slug>.<baseDomain>`) and binds the tenant
from the issuer host.
Rollback lever in [dlt/values.yaml](./dlt/values.yaml):
`ageCredentials.enabled=false` drops `AGE_KEY_FILE` (worker ignores
credential files, 0.1.0 behavior). The `pipelinesGit.enabled=false`
lever beside it is **gone** — the Phase 2.5 cleanup retired the
poll-is-truth mode it fell back to, and worker 0.9.0 requires
`PIPELINES_DIR`.

Save is driven by the worker: it POSTs TriggerSnapshot after every
successful pipeline run; `AUTOSAVE_INTERVAL` and the SIGTERM save are the
backstop. The sync loop exists for **break-glass state surgery** — edit
`state.json` in the Gitea UI (e.g. reset an incremental cursor to re-load a
window) and the box pulls it within `syncInterval` (5m), clean-tree only.
Conflict policy and recovery are identical to Rill's
([runbook](#rill-project-git-sync)); use `claimName: state-dlt-worker-0` and
mount path `/dlt-state` in the git-fix pod, and check
`dlt-snapshot:8484/debug/sync-status`.

## Fleet telemetry (Alloy → central)

The fleet-ops observability floor:
Grafana Alloy ([observability/](./observability/), chart `grafana/alloy`
1.10.0 — same pin as the central cluster) pushes **outbound-only** to
`https://ingest.<baseDomain>`
(the box sends basic auth, which the gateway matches as an Envoy
`apiKeyAuth` exact-value key):

- **Logs**: every pod on the box → central Loki, tenant (`X-Scope-OrgID`)
  = the customer slug — same tenant convention as the shared substrate, so
  the customer-erasure procedure applies unchanged.
- **Metrics** → central Prometheus `remote_write`, external labels
  `customer=<slug>, fleet=box`: node metrics (embedded node_exporter),
  **`argocd_app_info`** (per-app sync/health — the fleet-rollout feedback,
  Fable review #6), cert-manager expiry, kubelet cadvisor, and
  **PostgreSQL** (see below). A keep-list in
  the [River config](./observability/config/templates/configmap.yaml)
  bounds it to ~O(100) series per box; it must stay a superset of what the
  `fleet-box` alert rules query
  (`BoxGoneSilent`, `BoxArgoAppOutOfSync`/`Unhealthy`, `BoxDiskLow`,
  `BoxCertExpiringSoon`, `BoxBackupStale`, `BoxPostgres*` — evaluated on the
  receiving side, which is not part of this tree). The keep-list also carries
  `box_backup_last_success_timestamp_seconds` (the nightly-backup heartbeat,
  see [Backups](#backups)), scraped by node_exporter's textfile collector.
- **Traces**: dropped (v1) on this path — there is no central trace route.
  The local OTLP `:4317` receiver exists only so DuckFlight's exporter
  endpoint (`alloy.observability.svc:4317`) resolves. They do have a
  destination once the Better Stack flag below is on.

Credential chain: cloud-init stages Secret `alloy-ingest-auth`
(ns `observability`, username = slug); the same credential is aggregated —
as the exact `Basic <base64(slug:password)>` header value, keyed by slug —
into the central `alloy-ingest-keys` Secret on every worker apply. Rotation is create-time-frozen (pull-agent
territory, like the other centrally-known credentials). Tenant binding:
the gateway stamps the authenticated slug over `X-Scope-OrgID`
(`forwardClientIDHeader`), so a compromised box cannot push LOGS into
another tenant (`platform` is additionally dead-ended at the route).
Known v1 limit: the metrics `customer` label rides inside the
remote-write payload, which the gateway does not parse — forging it needs
the per-tenant enforcing proxy (follow-up).

### Better Stack, in parallel (evaluation, on since 2026-08-15)

Behind `betterstack.enabled` in
[observability/config/values.yaml](./observability/config/values.yaml), the
same three signals also go **direct** to a Better Stack Telemetry source that
belongs to this box alone — logs through an `otelcol.receiver.loki` bridge,
metrics as a second `remote_write` endpoint carrying the identical keep-list,
and traces to a real destination instead of the blackhole. Nothing above
changes: the central push is untouched whether the flag is on or off, which is
the point of running the two side by side before deciding anything.

Two properties are worth the duplication. **Direct** means the one path that
still reports when central is down — today every box signal dies with
`ingest.<baseDomain>`, which is precisely the moment we want to see the fleet.
**Per-box** means a source per customer: separable for erasure, and a token
whose disclosure by one box cannot touch another's data. A shared fleet token
on a machine the customer controls would be the opposite.

The credentials (source token + per-source ingesting host) arrive through
[box-secrets/](./box-secrets/) as Secret `betterstack-telemetry` in
`observability` — **not** cloud-init, because a source token has to be
rotatable. That ordering is the rollout: the Secret ships unconditionally and
lands first, and only once it is confirmed on the canary is the flag flipped.
Until then the Alloy volume is `optional: true` and simply empty.

**This was the day-2 channel's first real use, and it worked end to end
without anyone touching the box.** CI had already bumped `MODULE_REVISION_VM`;
the worker enqueued a drift intent on boot; the apply minted
`logtail_source.box`; the worker published the pair into `box_secrets`; the
box-secrets Job fetched them and wrote the Secret. No reprovision, no
cloud-init edit, no SSH — which is exactly what the cloud-init channel could
not do.

Verified on the canary box against that box's own Better Stack source, read
over the Query API: metrics and logs flowing within a minute of the config
reload, and 38 spans from a `telemetrygen` push at the box Alloy's `:4317` —
the traces path specifically, because that is the one the 2026-07-17 regression
left unwired while logs and metrics looked fine.

One rollout gotcha: two ArgoCD apps on the box did not notice the new
commit on their own and needed
`kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard
--overwrite`. A push is not a deploy until the app's `status.sync.revision`
says so.

### PostgreSQL metrics

The box's single PostgreSQL backs Casdoor, OpenFGA, Lakekeeper's catalog,
Gitea (the box's source of truth) and pipeline run state — so `pg_up` is the
closest thing the fleet has to a box-is-usable signal.
[prometheus-community/postgres_exporter](https://github.com/prometheus-community/postgres_exporter)
**v0.20.1** runs as a sidecar in the postgres pod
([postgres/statefulset.yaml](./postgres/statefulset.yaml), public image on
quay.io — boxes have no pull secret), same shape as the shared cluster:
it connects over `localhost`, so the superuser credential stays in the pod
that already mounts it, and `pg_up 0` can only mean the database — not the
network.

There is no prometheus-operator on a box, so Alloy scrapes the **pod IP**
(`:9187`) via pod discovery scoped to `stackNamespace`, relabelling
`namespace`/`pod` so the series match what the cluster's ServiceMonitor
produces and one Grafana dashboard renders both.

Nine hand-picked `pg_*` metrics are on the keep-list, each costing ~9 series
(one per database), with `template0`/`template1` dropped by a second relabel.
Two families are pointedly **excluded**: `pg_settings_*` is 270 static config
series, and `pg_stat_activity_*` carries `application_name`/`usename`/
`wait_event` labels that are unbounded by construction. `pg_settings_max_connections`
is named individually because `BoxPostgresConnectionsHigh` needs the
denominator. Alerts: `BoxPostgresDown`, `BoxPostgresConnectionsHigh`,
`BoxPostgresDeadlocks`.

### Legacy-box migration: alloy-ingest-auth

Boxes provisioned before 2026-07-17 never ran the amended cloud-init, so
the Alloy pod sits in `ContainerCreating` (missing Secret) until this
one-time step. Do it **after** the sync lands the real observability app
(hit live on the canary box: the pre-2026-07-17 observability *stub* app owned the
`observability` Namespace object, so the first sync of the real app pruned
the namespace — deleting a pre-staged Secret with it). The password
already exists in that box's own per-customer Terraform state after its first
post-amendment reconcile (the `random_password` is created even though
cloud-init won't deliver it):

Step 1 is to read that box's `alloy_ingest` password out of its own
per-customer Terraform state — an operator-side step against private
infrastructure, not something this repo describes.
Step 2 puts it on the box:

```bash
# ns observability exists once the sync lands — create it first if
# racing ahead of the sync:
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl -n observability create secret generic alloy-ingest-auth \
  --from-literal=username=<slug> --from-literal=password='<value>'
```

Canary verification: alloy DaemonSet pod Ready; DuckFlight logs
stop showing OTLP export errors; on the receiving Grafana, Loki tenant
`<slug>` shows box pod logs and Prometheus has
`up{customer="<slug>",fleet="box"}` + `argocd_app_info` per app; the
`fleet-box` alert group is present and green; unauthenticated
`curl -s -o /dev/null -w '%{http_code}' https://ingest.fairtier.com/api/v1/write`
→ 401. ✅ Ran end-to-end on the canary box 2026-07-19 (all checks green).

### Legacy-box migration: node-exporter textfile dir

Boxes provisioned before the backup-heartbeat landed (2026-07-19) never ran
the amended cloud-init, so `/var/lib/node-exporter/textfile` does not exist
(or is root-owned) and the non-root backup pod can't write its heartbeat →
`BoxBackupStale` would never clear. One-time step over ops SSH (the same
world-writable perms cloud-init now applies on new boxes):

```bash
ssh root@<box> 'install -d -m 1777 /var/lib/node-exporter/textfile'
```

The next nightly (or a manual `kubectl -n fairtier-system create job
--from=cronjob/box-backup box-backup-now`) then writes the `.prom` file and
the metric appears in central Prometheus within a scrape cycle. Done on the
canary box 2026-07-19.

<a id="legacy-box-migration-node-memory-floor"></a>
### Legacy-box migration: node memory floor

Boxes provisioned before 2026-08-10 have no
`/etc/rancher/k3s/config.yaml`, so they run with allocatable == capacity and
no memory eviction signal (see [the floor](#node-memory-floor)).

**Order matters: roll the request rebalance first.** The floor cuts
allocatable from 3819Mi to ~2851Mi, and a box whose requests still total
3070Mi will keep every running pod but put the next one to restart into
`Pending`. Verify the sync has landed the trims — `kubectl describe node`,
Allocated resources ≈ 2.4Gi / ~1.0 CPU — *then*:

```bash
ssh root@<box>
install -d -m 0755 /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'EOF'
kubelet-arg:
  - "system-reserved=cpu=100m,memory=128Mi"
  - "kube-reserved=cpu=250m,memory=640Mi"
  - "eviction-hard=memory.available<200Mi,nodefs.available<5%,imagefs.available<5%"
  - "eviction-minimum-reclaim=memory.available=100Mi,nodefs.available=10%,imagefs.available=10%"
EOF
chmod 0600 /etc/rancher/k3s/config.yaml
systemctl restart k3s          # control-plane blip; workloads keep running
```

Verification — allocatable is now below capacity, and the kubelet has a
memory signal to act on:

```bash
kubectl get node -o jsonpath='{.items[0].status.allocatable.memory}{"\n"}'   # 2920340Ki (2852Mi), was == capacity
kubectl get --raw "/api/v1/nodes/$(kubectl get node -o name | cut -d/ -f2)/proxy/configz" |
  jq '.kubeletconfig | {evictionHard, kubeReserved, systemReserved}'
kubectl describe node | sed -n '/Allocated resources/,/^Events/p'   # requests < allocatable
```

Rollback is `rm /etc/rancher/k3s/config.yaml && systemctl restart k3s`.

**Done on the canary box 2026-08-10**: allocatable 3819Mi → 2852Mi (`2920340Ki`) and
2 → 1650m CPU, `evictionHard` now
`{memory.available: 200Mi, imagefs.available: 5%, nodefs.available: 5%}`.
Requests 2382Mi of 2852Mi at rest (2446Mi while the quarter-hourly sync
CronJobs run), no pod Pending, no eviction. Restarting k3s surfaced the
cloud-init drift below — read it before restarting k3s on any other legacy
box.

<a id="cloud-init-drift"></a>
<a id="legacy-box-migration-argocd-qos"></a>
### cloud-init drift: every bootstrap manifest is a second writer

**k3s applies `/var/lib/rancher/k3s/server/manifests` at every k3s start,
not just the first** ([k3s docs](https://docs.k3s.io/installation/packaged-components):
applied "both on startup and when the file is changed on disk"). Read that
together with `user_data` being immutable — `ignore_changes`, because
changing it would replace the server — and every object cloud-init delivers
has two writers: a frozen one that fires at each boot, including the nightly
unattended-upgrades reboot, and the GitOps one that owns it day-2. The frozen
one runs last.

Seen on the canary box 2026-08-10 (provisioned 33 days before `439cf88`): one
`systemctl restart k3s` re-applied the provisioning-day
`fairtier-argocd.yaml` over the ArgoCD-owned `HelmChart` CR, the
helm-controller re-rendered from the old values, and all five ArgoCD pods
came back **BestEffort** — `oom_score_adj=1000`, the exact condition
`439cf88` fixed. **The flap does not self-correct** — that part was
observed: ArgoCD self-healed the CR and the pods stayed BestEffort anyway.
The mechanism is inferred, not proven: the helm-controller appears to decide
whether to re-render by comparing the install Job's spec rather than cluster
state, so a revert-then-selfHeal round trip returns the CR to the value the
existing Job was already built from, it sees no change, and the intermediate
render stays live. Recovery is to force the install Job to re-run:

```bash
kubectl -n kube-system delete job helm-install-argo-cd   # controller recreates it
kubectl -n argocd get pods -o custom-columns=N:.metadata.name,QOS:.status.qosClass
```

ArgoCD's QoS was only the instance that surfaced. The same mechanism sat
under the repo deploy token (rotate it and the next reboot restores the old
one — the problem publishing this tree dissolves outright),
the pinned ref (move a box and the reboot moves it back) and the nine
contract Secrets (rotation reverts). **Two fixes ship for it, and they are
structural, not per-box:**

1. **The ArgoCD values moved to a
   [`HelmChartConfig`](./argocd/templates/helmchartconfig.yaml).** The k3s
   helm-controller passes it to helm as an *additional* value file, so it is
   merged over whatever the frozen `HelmChart` carries — and nothing in
   cloud-init writes a `HelmChartConfig`, so it has exactly one writer. This
   arrives on every box through the GitOps sync, needs no SSH, and retires
   the "keep both in step" mirror rule for values. It does **not** cover
   `version` (a spec field, not values), and per-key merging means *removing*
   a key here does not remove it from the frozen copy — override it with the
   chart default instead.
2. **[bootstrap-retire/](./bootstrap-retire/)** writes a k3s `.skip` sentinel
   beside each cloud-init manifest once that file's GitOps twin exists,
   which retires the second writer permanently. `.skip` is non-destructive
   by design — per the k3s docs, creating one after an addon is deployed
   "will not remove or otherwise modify it or the resources it created", and
   only the file's existence matters. A Sync-hook Job runs it at every sync
   of that app (so one rollout retires the fleet) and a daily CronJob at
   02:07 covers a box whose guards were not yet satisfied then, ahead of the
   03:30 reboot window.

Order matters and is enforced structurally, not by hand: the sentinel for
`fairtier-argocd.yaml` is only written once the `HelmChartConfig` exists, so
a box can never be left skipping the file while its values are whatever the
last render produced.

What retirement costs, deliberately: those objects stop being re-created
from cloud-init. Deleting the `box-root` Application or the `fairtier-repo`
Secret becomes recoverable only over SSH — and that is the trade that makes
rotation, pin moves and values fixes survive a reboot. Undo on a box is
`rm /var/lib/rancher/k3s/server/manifests/<file>.skip`.

**The canary box, 2026-08-10** (before either fix): the on-disk manifest was brought
into step with the chart by hand (backup at
`/root/fairtier-argocd.yaml.bak-20260810`) and the pods came back Burstable.
That was one box, by hand, over SSH, per change — the reason both fixes
above exist. The manual edit stays harmless afterwards: the sentinel simply
stops the file being applied again.

**The general rule:** a "MIRRORS … keep both in step" comment keeps *new*
boxes correct and does nothing for boxes already running. Any object
delivered by cloud-init needs either a day-2 owner that outranks it (fix 1)
or the file retired (fix 2) — otherwise a change to it survives only until
the box next reboots.

## Backups

Nightly CronJob `box-backup` ([backup/](./backup/), 03:30 UTC — after
iceberg-maintenance at 02:30) writes everything stateful on the box into
**the customer's own bucket** (Secret `fairtier-storage` — per-customer R2
by default, BYOS otherwise), so the backup doubles as the portability
story:

```
s3://<bucket>/backups/
├── postgres/<db>/postgres_<db>_<ts>.sql.gz   # every non-template database
└── gitea/gitea_data_<ts>.tar.gz              # /var/lib/gitea: repos (dbt,
    gitea/gitea_config_<ts>.tar.gz            #   Rill, dlt state) + LFS
                                              # /etc/gitea: app.ini incl.
                                              #   autogenerated secrets
```

The dump covers every database, so `workspace_api` rides along — but its
credential columns are encrypted with the box-only key in Secret
`workspace-api-crypto` ([workspace-api seed
Job](./workspace-api/templates/seed-job.yaml)). A restore onto a *fresh*
box therefore needs that Secret carried over too, or the pipeline source
credentials and dbt git credentials in the dump are unreadable (everything
else restores normally). There is no central copy — that is the point.

Retention 7 days ([values.yaml](./backup/values.yaml)), matching the
platform postgres-backup and the Iceberg time-travel window. Iceberg data
is deliberately **not** copied — it already lives in the bucket; snapshot
expiry (7 days) is its oops-window, and bucket-level disaster recovery
remains the documented RPO gap.

**Failure visibility** — a nightly that fails is no longer silent (the
2026-07-19 incident went unnoticed ~15h). On a fully successful upload the
job writes a freshness heartbeat
`box_backup_last_success_timestamp_seconds` (epoch) to the host
node_exporter textfile dir `/var/lib/node-exporter/textfile`, which the box
Alloy scrapes (via its `/host/root` mount) and remote-writes to central
Prometheus; the central `BoxBackupStale` alert fires when the newest
success is >26h old. The dir is created world-writable (`1777`) by
cloud-init so the non-root (uid 1000) backup pod can write it — existing
boxes need the [one-time mkdir](#legacy-box-migration-node-exporter-textfile-dir).
That mode is a deliberate accepted cost, not an oversight: anything running
on the box can therefore write a `.prom` file and forge this box's own
freshness metric. The box is single-tenant and everything on it already runs
for one customer, so the only thing forgeable is that customer's view of
their own backup — narrow the mode to the uid instead if a box ever runs
workloads that are not ours.

Coverage map — why this set is complete: box Postgres holds Casdoor,
OpenFGA, Lakekeeper (all warehouse/table metadata) and Gitea's DB; the
Gitea data PVC holds the hosted repos, which are the durable home of the
dbt project, the Rill project, and dlt execution state (the Rill/dlt PVCs
are restorable clones of those repos); the Gitea config PVC holds
`app.ini`, whose autogenerated `INTERNAL_TOKEN`/JWT secrets must match the
DB dump for existing tokens to survive a restore. Dumps are per-database
transaction-consistent; the Gitea tar is taken live (nightly, refs update
atomically — an in-flight push at 03:30 is the accepted worst case).

**Restore** (fresh PVCs, same box): scale down the consumers
(`gitea`, then whichever of casdoor/openfga/lakekeeper is affected) →
`gunzip -c postgres_<db>_<ts>.sql.gz | psql -d <db>` per database (the
filename shape matches the central platform's backup tool,
so its `restore` command works too: `S3_PATH_PREFIX=backups/postgres/<db>`)
→ untar `gitea_data`/`gitea_config` into the recreated PVCs (uid/gid 1000)
→ scale back up. For a **box rebuild**, restore Postgres + Gitea the same
way after first boot; Rill and dlt then re-clone their repos from Gitea via
their `git-restore` inits.

## Hand-validation checklist

Known assumptions to verify before productizing. There is **no throwaway VM**
(Hetzner server shortage — the one
live box is all we have, and it must never be recreated), so validation
happens **in place**: move the live box's pin forward and check each
item there. A few behaviors only exercise on a first boot; those are parked
under "at next provision" and checked whenever the next box is created for
a real reason.

### In place, on the live box (canary rollout)

Status legend (against the live canary box): **✅ provably done** — recorded
in-place canary validation (dated) or de-facto by the box operating; **🟡
partially done** — mechanism proven, residual noted in-line; **unmarked** =
still needs an explicit check.

- ✅ **`bootstrap-retire` writes its three sentinels, and they hold across a
  k3s restart** — the check the 2026-08-10 incident failed
  ([cloud-init drift](#cloud-init-drift)). **Canary roll 2026-08-10 23:31Z
  (`4ebafc0a`), restart test 23:39:57Z:**
  - The **`HelmChartConfig` takes over cleanly, with no churn.** The CR's own
    `valuesContent` is now empty and Secret `chart-values-argo-cd` carries
    ours under `HelmChartConfigValuesContent`; the rendered specs are
    unchanged (controller `50m/256Mi`, repo-server `livenessProbe`
    `timeoutSeconds: 5`), all five pods still **Burstable**, `0` restarts,
    same pod ages as before the roll. So the merge does apply to a chart k3s
    did not package — the open question at authoring time.
  - The **guard held the ordering by itself.** The hook Job ran at 23:31:38,
    before the `argocd` app had re-polled the branch, and logged
    `fairtier-argocd.yaml: waiting — no HelmChartConfig/argo-cd yet` while
    retiring the other two. The third sentinel followed once the config
    landed (run early, `--from=cronjob/bootstrap-retire`, rather than
    waiting for the 02:07 tick).
  - **The restart is a non-event, which is the whole point.** With all three
    sentinels in place, `systemctl restart k3s` (back Ready in 19s) left the
    ArgoCD pods *untouched* — five Burstable, `0` restarts, still their
    pre-restart start times — the CR's `valuesContent` still empty and
    `version` still `9.5.21`. The proof that k3s skipped the files rather
    than re-applying them: the three `Addon` resources
    (`kubectl -n kube-system get addons.k3s.cattle.io`) came back with
    **byte-identical `resourceVersion`s**, as did ConfigMap `box-config`.
    Nothing the files carry was re-asserted, and nothing they had created
    was removed — the k3s docs' claim about a post-deployment `.skip`,
    confirmed on a real box. Compare with the same restart on
    2026-08-10, which cost five BestEffort pods and a manual
    `delete job helm-install-argo-cd`.
  - Unrelated churn in the same window, for whoever reads the timestamps:
    `01b380be` (box image roll) landed at 23:38 and re-rolled
    rill/dlt-worker/duckflight/workspace-api. Those syncs, not the restart,
    recreated those pods; all 19 apps were Synced+Healthy afterwards.
- ✅ Casdoor honors the `dataSourceName` **environment variable** over the
  empty value in `app.conf` (env-first config lookup).
- ✅ Lakekeeper `migrate` creates/uses OpenFGA store `lakekeeper` when the
  store does not pre-exist (shared path pre-creates it via Terraform).
- ✅ The lakekeeper chart's `service.port: 8080` + backend port `8181`
  combination (copied verbatim from the shared path) exposes the catalog on
  service `lakekeeper:8181`.
- ✅ DuckFlight tolerates the unreachable otel endpoint until Phase-5 Alloy
  lands (traces dropped, queries unaffected).
- ✅ `auth.k8s` bootstrap semantics on the box (worker bootstraps over the
  public URL; the in-cluster audience is box-local).
- ✅ Traefik `IngressRoute` + `scheme: h2c` round-trips FlightSQL gRPC.
- ✅ **The casdoor-seed Job's legacy adoption** — the critical in-place check,
  do it first and watch closely: it must extract the client pairs/admin
  password from the cloud-init `casdoor-init-data`, materialize
  `lakekeeper-oidc`/`web-oidc`/`duckflight-iceberg-secrets`/
  `casdoor-admin-credentials`, and re-render init_data **without changing
  Casdoor's DB objects** (`initDataNewOnly = true` skips existing ones —
  verify against our pinned image). Compare the extracted `lakekeeper-oidc`
  values with the worker's ActualConfig; confirm the casdoor restart (the
  rendered JSON will differ from the legacy bytes, so one restart is
  expected) comes back healthy and logins still work.
- ✅ The gitea-seed Job's assumptions: Casdoor's management API accepts
  `clientId:clientSecret` Basic auth from a seeded org application (the
  `web` app) for `get-application`/`add-application` — if org-scoped apps
  can't create applications, fall back to an org-admin `/api/login`
  session using the credentials in `casdoor-init-data`.
- ✅ The gitea-init Job's assumptions: `gitea migrate` + `gitea admin` CLI work
  DB-direct from a fresh pod (ephemeral emptyDir config), and
  `admin auth add-oauth` reaches the on-box Casdoor discovery URL over the
  public hostname (hairpin through servicelb/Traefik).
- ✅ Casdoor OIDC login to Gitea auto-provisions the user
  (`ALLOW_ONLY_EXTERNAL_REGISTRATION` + `oauth2_client` auto-registration).
  Config verified in place on the box (2026-07-17): app.ini has
  `ALLOW_ONLY_EXTERNAL_REGISTRATION = true`, `ENABLE_AUTO_REGISTRATION = true`,
  `ACCOUNT_LINKING = auto`, `USERNAME = nickname`, and the `casdoor` OAuth2
  login source (type 6) is active. Browser round-trip done 2026-07-17: a
  "Sign in with casdoor" login auto-provisioned a real Gitea user
  (`gitea admin user list` now shows `admin` (id 2, non-admin, external)
  alongside the seeded `fairtier-admin`). Note the provisioned account is a
  plain user with no access to `fairtier-admin`'s private repos — so the box
  repos are invisible to a customer's personal Gitea login **by design**
  (repos are platform-managed; customers edit through the Console, not Gitea).
- ✅ **Rill's vended-credentials read path** — the one deliberate delta from
  the (hand-validated) shared-path Rill config: the box ATTACH omits
  `ACCESS_DELEGATION_MODE 'none'` + the static S3 secret and relies on
  Lakekeeper vending temporary R2 credentials, same as box DuckFlight —
  but through the DuckDB/iceberg-extension build *bundled in
  `rilldata/rill:v0.87.2`*, which is older than DuckFlight's. Check:
  `SELECT * FROM lk.<ns>.<tbl>` from the Rill UI returns rows. Fallback if
  it can't do vending: re-add the S3 secret to `conn_init_sql` with
  `ACCESS_DELEGATION_MODE 'none'`, sourcing the cloud-init R2 credentials
  already present in `fairtier-system`.
- ✅ oauth2-proxy against Casdoor: OIDC discovery over the public
  `auth.customer-<slug>` hostname (hairpin — gitea-init precedent), issuer
  match (Casdoor `origin` == `--oidc-issuer-url`), login round-trip sets
  the session cookie, and Casdoor's ID token carries the `email` claim
  oauth2-proxy requires. Verified 2026-07-17: Casdoor discovery reports
  `issuer: https://auth.customer-<slug>.fairtier.com` (exactly
  `--oidc-issuer-url`) with `email` in both `scopes_supported` and
  `claims_supported`, and oauth2-proxy is configured
  `--scope=openid profile email`. **Browser round-trip completed 2026-07-17**:
  login lands in the app at `rill.`, `dashboards.`, and `git.`
  customer-`<slug>`. Three seed-side fixes were needed to unblock the callback
  (all now in the casdoor-seed IaC, none by hand): org `languages: ["en"]`
  (a null `languages` crashed the Casdoor login SPA → `/login/oauth/undefined`),
  and the org-admin user gaining `email` + `emailVerified: true` (oauth2-proxy
  rejects a missing/unverified email claim with a callback 500).
- Rill's SSE stream (`/v1/instances/*/sse`) survives oauth2-proxy
  (~1s flush interval) + Traefik — no mid-stream severing (the shared path
  needed an explicit `0s` request timeout on Envoy; Traefik defaults to no
  response timeout).
- 🟡 The rill StatefulSet's PVC + copy-project overlay: a pod restart keeps
  customer-authored dashboards, a ConfigMap change rolls the pod (checksum
  annotation) and the git-managed files win. Mechanism verified 2026-07-17:
  the pod template carries `checksum/rill-project` (a config change flips the
  hash → StatefulSet rolls the pod); the project lives on a `volumeClaimTemplate`
  PVC `project-rill-0` (Bound, survives pod replacement by construction) with
  a `git-restore` init that adopts it; the git tree tracks only `.gitignore` +
  `README.md` while the platform files (`rill.yaml`, `duckdb.yaml`, `.env`) are
  correctly gitignored (copy-project overlay wins), and the git log shows real
  sidecar+remote sync commits (adoption already drilled 2026-07-12). Residual:
  no customer dashboard has been authored yet, so "restart keeps *dashboards*"
  can only be positively shown once one exists (browser).
- ✅ **dbt transformations — hosted repo seed** (validated 2026-07-10):
  the dlt-seed Job created `fairtier-admin/transformations` with the
  starter project intact (Helm-escaped Jinja files byte-identical) and
  Secret `transformations-git` holds a working read-only token (clone
  succeeds, push denied 403). Caught+fixed live: the Secret's name was
  missing from the seed Role's `resourceNames`, so re-syncs mistook
  forbidden-get for absent and rotated the Gitea token out from under
  the Secret — the seed now treats only NotFound as absent.
- ✅ **dbt transformations — run path** (validated 2026-07-10, worker
  0.0.4 + a FairTier API deploy): triggered runs clone at `main`, generate
  profiles.yml, and `dbt build` the starter models into
  `lake.staging`/`lake.marts` **via vended credentials** (no S3 secret in
  the profile). Run report: commit SHA, 2 models + 2 tests, success and
  failure notifications; a deliberately broken model produced a
  credential-free per-model error. Caught+fixed live: dbt needs a
  writable cwd (worker 0.0.4) and an Iceberg-safe table materialization
  (seeded macro — duckdb-iceberg can't RENAME a just-written table nor
  CREATE one dropped in the same transaction).
- 🟡 **Iceberg maintenance CronJob**: trigger a manual run
  (`kubectl create job --from=cronjob/iceberg-maintenance ...`). Check the
  log: a many-small-files dlt table reports `compacted N files`, a
  DuckFlight-mutated table (run an `UPDATE` via the Console SQL editor
  first) reports the merge-on-read skip, and the per-table Casdoor
  client-credentials → Lakekeeper catalog auth works (`dlt-oidc` reuse —
  pyiceberg sends its default oauth2 scope; if Casdoor rejects it, set an
  explicit `scope` in the catalog properties). Confirm post-compaction
  `SELECT`s from DuckFlight/Rill still return the same rows. Every table
  also logs a `snapshot expiry:` outcome (`expired N of M snapshots` or
  `nothing to expire`); after an expiry pass, a time-travel query within
  the 7-day window still works and one older than the window fails.
  (Lakekeeper's own maintenance task queues are enterprise-only — nothing
  to validate on the warehouse.)
- 🟡 **Orphan sweep, on a new box**: the same run ends with
  `N orphan file(s) / X MiB unreachable (0 deleted, mode=dry-run)` — dry-run
  is the correct state for a box that has not been armed, and
  `iceberg_maintenance_orphan_sweep_refused` must be **0** (a refused table
  reports zero orphans, so a non-zero count means that number is blind, not
  clean). Arming the box is a separate, deliberate procedure with its own
  proof — never a side effect of provisioning it.
- ✅ **rill-seed log** shows repo `fairtier-admin/rill` created +
  README/.gitignore seeded + Secret `rill-git` minted (a seed failure before
  `rill-git` leaves the pod
  in `CreateContainerConfigError` — check the seed log first). First boot:
  the `git-restore` init adopts the PVC (`adopted existing directory` in its
  log) with a clean tree — inspect
  `rill-snapshot:8484/debug/sync-status` (`state: in-sync`) *before* the
  first autosave and check `git status`-visible strays; anything non-ignored
  left on the PVC gets committed by the first save. Repo existence confirmed
  live 2026-07-17: the box Gitea holds all three platform repos —
  `fairtier-admin/rill`, `fairtier-admin/dlt`, `fairtier-admin/transformations`
  (all private, non-empty, on disk at `/var/lib/gitea/git/repositories/`), and
  `dlt.git` was last written the same day (dlt has run and pushed state).
- 🟡 Rill UI edit → autosave (≤5 min) → commit visible in Gitea; edit a file in
  the Gitea UI → box pulls within `syncInterval` (1m) and Rill hot-reloads
  it.
- 🟡 **Rill viewer (`dashboards.`)** — day-2 on the live box: the re-run seed
  Job logs `viewer redirect URI registered` (Casdoor `rill` app updated in
  place — verify the *editor* login still works after, since the update
  re-stamps the client secret from `rill-oidc`); `rill-viewer-0` Running,
  Certificate `rill-viewer-tls` Ready. Login at `dashboards.customer-<slug>`
  verified 2026-07-17 (viewer oauth2-proxy round-trip completes, same Casdoor
  `rill` client, second redirect URI) and the editor login still works after.
  Residual: no customer dashboard authored yet, so "shows dashboards with **no
  code editor/file tree**" and "an editor-side change lands within autosave
  (≤5 min) + sync (≤15 s)" can only be shown positively once one exists.
  `kubectl top pods`: the second Rill + DuckDB fits the box's memory headroom.
- ✅ **Console Save → immediate publish** — seed Job creates `platform-git`
  and `rill-snapshot-auth` (it logged `… deposited to central` too, until
  split Phase 3E); Certificate `rill-snapshot-tls` Ready. An unauthenticated
  `POST https://rill-snapshot.customer-<slug>…/snapshot.v1.SnapshotService/TriggerSnapshot`
  returns **401**; the Console Save button (Apps view, Rill card) returns
  `created`/`unchanged` and the commit appears in Gitea immediately, on
  `dashboards.` within ~15 s. Requires central to run the migration-0026
  build and the sidecar image `0.2.0` to exist on GHCR (tag `v0.2.0`).
- ✅ Conflict drill on the live box: local UI edit + Gitea edit →
  `/debug/sync-status` reports `dirty`/`diverged`, save returns
  `remote_changed`, and the [runbook](#rill-project-git-sync) recovers.
- ✅ **casdoor-seed day-2 app addition (dlt-worker)** — the first time an
  `initDataApplications` entry is *added* on a live box: the seed mints
  `dlt-oidc`, re-renders init_data (create-only, `initDataNewOnly`),
  restarts casdoor (must come back healthy, **logins still work**), and the
  new audience-change branch restarts lakekeeper. Then verify lakekeeper
  accepts a `dlt-oidc` client-credentials token (audience reload — ranked
  failure #2).
- ✅ **Box-issuer trust end-to-end** (do before the rollout — the FairTier API
  deploys via its own CI): from a laptop, mint a client-credentials token
  from the box Casdoor and POST
  `worker-api.fairtier.com/pipeline.v1.PipelineService/GetPipelineConfigs`
  → 200 for the matching `customerSlug`, `permission_denied` for a foreign
  slug, `unauthenticated` for a garbage token. Non-PipelineService paths on
  that hostname must 404 (health/reflection stay cluster-only).
- ✅ dlt-seed log shows repo `fairtier-admin/dlt` created + README/.gitignore
  seeded + Secret `dlt-git` minted (failure before `dlt-git`/`dlt-oidc`
  leaves the pod in `CreateContainerConfigError` — check the seed logs
  first). `git-restore` adopts the empty PVC; `dlt-snapshot:8484/debug/sync-status`
  reports `in-sync`.
- ✅ **dlt writer-grant window** (ranked failure #1): until the platform
  worker's next reconcile registers `oidc~admin/dlt-worker` as warehouse
  writer, pipeline runs 403 on the catalog and report `failed` in the
  Console — trigger a reconcile promptly after the rollout and confirm
  self-heal.
- ✅ dlt E2E: create/trigger a pipeline in the Console → the box worker picks
  it up within `POLL_INTERVAL_SECONDS` (60s) → run `success`, rows counted →
  commit in Gitea `fairtier-admin/dlt` containing **only** `state.json` +
  `schemas/` (no `trace.pickle`, `load/`, `normalize/`). Pod restart keeps
  state (PVC); cursor-reset drill: edit `state.json` in Gitea → box pulls
  within 5m → next run re-loads from the edited cursor. State-sync half
  provably done 2026-07-17: the `/dlt-state` git tree holds exactly
  `.gitignore`, `README.md`, `My File/{state.json,schemas/…}` and
  `jsonplaceholder-posts/{state.json,schemas/…}` — **no** `trace.pickle`,
  `load/`, or `normalize/`; the sidecar is healthy
  (`saved key=main@302975… backend=git`). **Run now proven 2026-07-17**: a
  Console "Run now" on `jsonplaceholder-posts` (`TriggerPipeline`) was picked
  up by the worker in **~20 s** (well under the 60 s poll), ran `success` with
  **110 rows loaded** (100 posts + 10 users — exact), and `ReportPipelineRun`
  advanced the central `lastRunAt` to 21:09 (the count the Console shows). The
  sidecar logged `snapshot unchanged` and correctly committed nothing —
  `append` with no incremental cursor means state is stable run-to-run, so
  `_last_extracted_at` (2026-07-09) does **not** advance; the tracked-set
  discipline is shown instead by the earlier `My File` commit `302975d`
  (stat: only `My File/state.json` + `My File/schemas/my_file.schema.json`).
  **Pull channel proven on the dlt repo 2026-07-17**: editing
  `My File/state.json` in Gitea (a sentinel `_last_extracted_at`) and committing
  to `main` was fast-forward-pulled onto the box in **~170 s** (< the 5 m
  `syncInterval`, clean-tree only) — the box's on-disk state flipped to the
  sentinel and its dlt repo HEAD advanced to the edit commit; reverted after.
  This is the break-glass *pull* direction end-to-end on dlt state (previously
  only inferred from the shared Rill sidecar code). Residual: the cursor-reset
  *reload effect* (edited cursor → different rows load) needs a genuinely
  **incremental** pipeline — **none of the three current pipelines qualify**:
  `jsonplaceholder-posts`/`test` are `rest_api` `append` with no incremental
  hint, and `My File` is `dlt.destinations.filesystem` `append` whose
  `state.json` has **no `sources` block at all** (it re-reads `export.csv`
  every run by design — there is no file cursor to reset). Closing it means
  first creating an incremental pipeline (e.g. jsonplaceholder `/posts`
  incremental on `id`). **Worker incremental bug found + fixed 2026-07-17**:
  an `incremental-posts` pipeline (top-level `incremental.cursor_path: id`)
  loaded all 100 rows and persisted **no `sources` cursor** — the dlt-worker's
  `_build_rest_api_source` only read `incremental` **per-resource**, while
  the FairTier API validates and the Console emits it **top-level**, so it was
  silently dropped and the run was a plain non-incremental append. Fixed in
  `dlt-worker` **0.0.11** (source-level `incremental` applied to every resource,
  per-resource still overrides). Two-step fix worth noting: 0.0.10 first placed
  the incremental at the **resource** level as a `dlt.sources.incremental`
  object, which dlt's rest_api rejects (`EndpointResource received unexpected
  fields {incremental}`) — the 0.0.10 unit tests mocked `rest_api_source` so dlt
  never validated the shape; 0.0.11 puts it as an `IncrementalConfig` **dict
  under `endpoint`** (dlt's actual shape) and adds **unmocked** construction
  tests that would have caught it. **Cursor-reset drill closed 2026-07-18** on
  0.0.11: run 1 → **100 rows**, state.json now carries a real cursor
  (`sources.rest_api.resources.posts.incremental.id.last_value = 100`); run 2 →
  **0 rows** (dlt gates `id > 100`); then editing `last_value` `100 → 50`
  (unique_hashes cleared) in Gitea was fast-forward-pulled onto the box in
  ~220 s and the next run loaded **51 rows** (ids 50–100 — the boundary row is
  included because dlt's incremental start is *closed* (`>=`) and the dedup
  hashes were cleared), re-advancing the cursor to 100. The 0.0.10→0.0.11 box
  roll also proved **pod restart keeps state** (the cursor survived the pod
  replacement on the volumeClaimTemplate PVC). All halves of this item —
  Run-now/row-count, commit discipline, break-glass pull, and the incremental
  cursor-reset differential — are now validated live.
- ✅ **pipelines-as-files Phase 3 — age-credential fresh-pod outage drill**
  (validated 2026-07-19,
  rollout step 4). The
  strong acceptance invariant *fresh process + central down + `.age` present
  ⇒ run fires with file-decrypted credentials* was exercised live on the canary box.
  Setup: `basic-auth-test` (the box's one credentialed pipeline —
  `pipelines/basic-auth-test.credentials.age`, armored age) was given a
  `*/5 * * * *` schedule via the Console (mirrored to the box `pipelines`
  repo, sidecar-pulled in ~30 s). Drill: paused central
  `argocd-application-controller` (sts→0) **and** `platform-api` (deploy→0),
  then deleted `dlt-worker-0` to force a fresh pod with an **empty in-memory
  credential cache**. The fresh pod (13:58:28Z) never once reached
  `worker-api` — every `GetPipelineConfigs`/`ReportPipelineRun` returned
  `503` — so the poll cache stayed empty, leaving the `.age` file as the
  **only** possible credential source. At **14:00:46Z** the local `*/5` cron
  fired from file truth: `Running pipeline: Basic Auth test` →
  `completed: 1 rows loaded` (httpbin `/basic-auth` 200 ⇒ the credential
  decrypted correctly), while `ReportPipelineRun` failed `503` as a clean
  logged error that never touched the run or the loop. Restore: scaled
  `platform-api`→2 and the app-controller→1; the worker flipped back to
  `ready:true` and the next run (**14:20:26Z**, 1 row) reported to central
  with **zero** report failures — history caught up. Confirms the Phase-2
  readiness note holds (a central-outage poll failure keeps the pod
  `NotReady` while files-mode scheduling and age-decryption keep working).
  `POLL_SOURCE_CREDENTIALS=off` shipped on the strength of this drill the same
  day; the drill-only `*/5` schedule on `basic-auth-test` was reverted with it.
- ✅ **Casdoor's `built-in` bootstrap admin is rotated at seed** (2026-07-17).
  Casdoor creates that account itself at first startup, so it pre-exists our
  init_data and `initDataNewOnly` cannot touch it — it needs an explicit
  rotation rather than a seeded value.
  [casdoor-seed](./casdoor/templates/seed-job.yaml) step 5 replaces the
  bootstrap credential with a strong random password persisted in Secret
  `casdoor-builtin-admin` (break-glass only): idempotent (skips once the stored
  password logs in), waits for casdoor to serve (covers a step-3 restart), and
  defers on first boot until casdoor is up. Canary-verified — the seed logged
  `built-in/admin password rotated`, the bootstrap credential no longer
  authenticates, and box apps stayed Healthy. **Check the seed log after any
  casdoor roll:** a deferred or failed rotation logs a `WARNING:` line and the
  Job still exits 0, so it is not visible as a failed sync.
- 🟡 ArgoCD adopting the bootstrap `HelmChart` CR ([argocd/](./argocd/)): the
  k3s deploy controller must not stomp the GitOps-updated CR on k3s
  restart (the manifest file's checksum is unchanged, so it should skip;
  if it does stomp, selfHeal converges back — watch for churn). Then bump
  the pin and watch the helm-controller upgrade ArgoCD in-place.
- ✅ The self-managed root app ([apps/templates/root-app.yaml](./apps/templates/root-app.yaml)):
  ArgoCD adopts the cloud-init-written `box-root` without a self-prune
  loop, and a chart-side spec change (e.g. a retry tweak) converges.
- ✅ The ensure-databases Job creates the `gitea` database on the live box
  (the other three already exist from initdb).
- ✅ **Backup CronJob** ([backup/](./backup/)) — manual run validated on the
  canary box 2026-07-19: the dump init logged one `dumping <db>` per database +
  `archiving gitea`; the upload's `rclone lsl` listed `postgres/<db>/…sql.gz`
  for every database plus both gitea tars; the second-pod-mounts-the-RWO-Gitea-PVCs
  assumption held on local-path (pod scheduled, no volume-attach wedge);
  `RCLONE_CONFIG_DEST_PROVIDER=Cloudflare` + `no_check_bucket` uploaded with
  the scoped `fairtier-storage` token. The **freshness heartbeat** also
  works: the job wrote `box_backup_last_success_timestamp_seconds` (as uid
  1000 into the `1777` textfile dir) and it reached central Prometheus, where
  `BoxBackupStale` is loaded and `health=ok` (see [Backups](#backups)). The
  read-only restore drill (download a dump + `gunzip -t`, `tar -tzf` both
  gitea tars) was covered by the 2026-07-19 restorability drill.
  **Residual:** after 8+ nights, confirm retention pruned night 1
  (`--min-age` uses upload mtime).

### At next provision (first-boot-only behavior — no box gets created for this)

- First-sync ordering: cert-manager CRDs vs. `ClusterIssuer`/`Certificate`
  (mitigated by `SkipDryRunOnMissingResource` + retries).
- First-sync wave choreography of the seeds on an empty cluster
  (RBAC −2 → seed −1 → consumers 0, casdoor app before gitea app).
- The casdoor-seed Job from the slim contract: `lakekeeper-oidc` comes from
  cloud-init, everything else is generated, and Casdoor **generates the JWT
  cert** when the init_data cert entry carries no `certificate`/`privateKey`
  (`populateContent()` → `generateRsaKeys`, verified in source v1.99x).

## Related

- [PUBLIC.md](./PUBLIC.md) — what publishing this tree means, and where the
  images come from
- [apps/values.yaml](./apps/values.yaml) — the fleet-wide version pins and
  feature gates every chart here reads
