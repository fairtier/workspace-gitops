# Observability — box Alloy → central ingest

The fleet-ops observability floor of the dedicated-VM substrate:
Grafana **Alloy** (upstream chart `grafana/alloy` **1.10.0** — pinned in
[../root/values.yaml](../root/values.yaml) `alloyChartVersion`, the same
version the central cluster runs)
shipping **outbound-only** to `https://ingest.<baseDomain>`
(basic auth from Secret `alloy-ingest-auth` — matched at the gateway as an
Envoy `apiKeyAuth` exact-value key, which also stamps the authenticated
slug over `X-Scope-OrgID`):

- pod logs → central **Loki**, tenant = customer slug;
- node / **ArgoCD (`argocd_app_info`)** / cert-manager / cadvisor /
  **PostgreSQL (`postgres_exporter` sidecar, pod IP `:9187`)** metrics →
  central **Prometheus** `remote_write`, external labels
  `customer=<slug>, fleet=box`, bounded by a keep-list;
- a local OTLP `:4317` receiver so the `otel.endpoint` in
  [../duckflight/values.yaml](../duckflight/values.yaml) resolves — traces
  are **dropped** (no central trace path, v1).

Layout — two sources composed by
[../root/templates/observability.yaml](../root/templates/observability.yaml):

- [values.yaml](./values.yaml) — static values for the upstream chart
  (DaemonSet, mounts, ports, `alloy.enableReporting: false`);
- [config/](./config/) — mini chart rendering the per-box River config
  (needs `slug`/`baseDomain`/`stackNamespace` templating) as ConfigMap
  `alloy-config`, plus the supplementary `nodes/metrics` RBAC for the
  cadvisor scrape.

Operational details (credential chain, legacy-box migration, canary
verification, alert rules): [ARCHITECTURE.md — Fleet telemetry](../../ARCHITECTURE.md#fleet-telemetry-alloy--central).
