# 03 — Observability Stack (Prometheus, Grafana, Loki, OpenTelemetry)

> Golden-standard research for the observability layer: metrics (Prometheus), dashboards
> (Grafana), logs (Loki), and the telemetry pipeline (OpenTelemetry). Everything here is deployed
> as an ArgoCD Application → upstream Helm chart (doc 02). Platform is doc 01.
> Research date: 2026-07.

---

## 0. TL;DR — the integrated 2026 pattern

```
   app pods (OTLP)                    kubelet / cAdvisor / node-exporter
        |                                        |
        v                                        v (scrape)
  +------------------+  metrics (remote_write / scrape)  +--------------+
  | OTel Collector   | --------------------------------> |  Prometheus  |
  | (DaemonSet +     |  logs (otlphttp -> /otlp/v1/logs) +--------------+
  |  Deployment)     | ------------------+                       |
  |                  |  traces           |                       |
  +------------------+   (-> Tempo,      v                       |
        ^  auto-instr        out of    +--------+                |
        |  (Instrumentation  scope)    |  Loki  |                |
        |   CRD)                        | (S3)   |                |
     app pods                          +--------+                |
                                            |                    |
                                            v                    v
                                        +--------------------------+
                                        |         Grafana          |
                                        |  datasources: Prometheus |
                                        |  + Loki (+ Tempo later)  |
                                        +--------------------------+
```

Key 2026 shifts vs the old stack:
- **Promtail is DEPRECATED** (LTS since Feb 2025) → use **Grafana Alloy** OR the **OTel Collector**
  for log collection.
- **Loki 3.x has a native OTLP endpoint** (`/otlp/v1/logs`) → the OTel Collector ships logs with
  the standard `otlphttp` exporter; the old dedicated `loki` exporter is deprecated.
- **OTel Collector becomes the single telemetry pipeline** (metrics + logs + traces), reducing the
  number of agents on each node.

---

## 1. kube-prometheus-stack (metrics + Alertmanager + Grafana bundle)

- **Chart:** `prometheus-community/kube-prometheus-stack`, current **87.16.1** (2026-07).
  Source: https://github.com/prometheus-community/helm-charts/releases
- **Bundles:** Prometheus Operator, Prometheus, Alertmanager, **Grafana**, node-exporter,
  kube-state-metrics, and the ServiceMonitor/PodMonitor CRDs.
- **CRD pattern:** scrape targets are declared as `ServiceMonitor`/`PodMonitor` CRs, not scrape
  config. Your apps expose `/metrics`; you drop a ServiceMonitor next to them (sync wave 3).

### Cost-conscious values (portfolio cluster)

```yaml
# gitops/apps/kube-prometheus-stack/values.yaml
prometheus:
  prometheusSpec:
    retention: 7d                      # short retention = small disk = cheap
    retentionSize: "8GB"
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { memory: 1Gi }
    storageSpec:                       # gp3 PVC via ebs-csi (doc 01)
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          resources: { requests: { storage: 10Gi } }
    # remoteWrite: []  # OFF — no external TSDB cost for a portfolio cluster

alertmanager:
  alertmanagerSpec:
    resources: { requests: { cpu: 50m, memory: 64Mi } }

grafana:
  enabled: true                        # use the bundled Grafana (see section 2)
```

Levers that matter: `retention: 7d` + `retentionSize` cap disk; `remoteWrite` stays OFF (no
managed-Prometheus bill); modest resource requests keep it on a single spot node.

---

## 2. Grafana

```
Rank  Option                                  Use for
1.    Bundled in kube-prometheus-stack        ← RECOMMENDED (one less chart)
2.    Standalone grafana/grafana chart        multi-source dashboards, HA Grafana
```

**Decision:** use the Grafana bundled in kube-prometheus-stack — it auto-wires the Prometheus
datasource and ships the standard K8s dashboards. Add Loki as a second datasource and provision
dashboards as code.

### Datasource + dashboard provisioning (as code, committed to repo)

```yaml
grafana:
  # admin password comes from ESO (doc 02 section 6), NOT plaintext here
  admin:
    existingSecret: grafana-admin-credentials
    passwordKey: admin-password

  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki-gateway.logging.svc.cluster.local     # section 3
      access: proxy

  # Sidecar watches for ConfigMaps labeled grafana_dashboard=1 and loads them.
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: ALL
```

Commit dashboards as `ConfigMap`s labeled `grafana_dashboard: "1"` under
`gitops/apps/grafana-dashboards/` — the sidecar auto-loads them, so dashboards are version-
controlled and restored on a fresh cluster (portfolio win). Prometheus is auto-added by the
bundle; Loki is added via `additionalDataSources`.

---

## 3. Loki (logs)

- **Version:** Loki **3.x**. Native OTLP ingestion endpoint at `/otlp/v1/logs`.
- **Chart:** the current `grafana/loki` chart. AVOID the old **`loki-stack`** chart — it bundles
  the now-deprecated Promtail and is effectively legacy.

### Deployment mode (ranked for a cost-conscious cluster)

```
Rank  Mode                     Complexity  Cost   Use for
1.    SingleBinary (monolithic) low        low    portfolio / small  <- THIS PROJECT
2.    SimpleScalable (SSD)      medium      med    growing; read/write/backend split
                                                   (NOTE: SSD being deprecated in Loki 4.0)
3.    Distributed (microservices) high      high   large multi-tenant only
```

**Decision:** **SingleBinary** (monolithic) mode — one Loki process, minimal footprint, perfect
for a meta-monitoring stack that logs a small portfolio cluster. Source:
https://grafana.com/docs/loki/latest/get-started/deployment-modes/

### Storage: S3 (not filesystem)

```
Rank  Backend            Survives teardown?  Use for
1.    S3 (chunks+TSDB)   YES  <- RECOMMENDED  logs persist across cluster rebuild
2.    Filesystem PVC     NO                   lost on teardown; dev-only
```

Loki writes chunks + the TSDB index to **S3**. Auth via **IRSA** (Loki historically documents
IRSA for S3; Pod Identity support tracked in grafana/loki#12624 — use IRSA here if Pod Identity
isn't wired, per doc 01 section 3). S3 storage is why logs survive `make down`/`make up`.

```yaml
# gitops/apps/loki/values.yaml
deploymentMode: SingleBinary
loki:
  storage:
    type: s3
    bucketNames: { chunks: eks-golden-loki-chunks, ruler: eks-golden-loki-ruler }
    s3: { region: us-east-1 }        # creds via IRSA/Pod Identity, not keys
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb                   # TSDB index (current standard)
        object_store: s3
        schema: v13
        index: { prefix: loki_index_, period: 24h }
  limits_config:
    retention_period: 168h            # 7d retention = cheap
  # Enable the native OTLP endpoint so the OTel Collector can push logs directly
singleBinary:
  replicas: 1
  persistence: { storageClass: gp3, size: 10Gi }
```

### How logs get INTO Loki (ranked, 2026)

```
Rank  Collector           Status         Use for
1.    OTel Collector      current        unified metrics+logs+traces  <- THIS PROJECT
      (otlphttp exporter
       -> Loki /otlp/v1/logs)
2.    Grafana Alloy       current        Grafana-native successor to Promtail
3.    Promtail            DEPRECATED      LTS since Feb 2025 — do NOT start new work on it
```

**Decision:** OTel Collector as the log shipper (section 4) — one agent for all three signals.
Alloy is the equally-valid Grafana-native choice; pick OTel Collector here to make OpenTelemetry
the spine of the whole pipeline (stronger portfolio narrative). Promtail deprecation source:
https://grafana.com/docs/loki/latest/send-data/promtail/ (LTS notice), and the Alloy migration
ADR: https://docs-bigbang.dso.mil/latest/docs/adrs/0004-alloy-replacing-promtail

---

## 4. OpenTelemetry (the unified pipeline)

- **Operator chart:** `open-telemetry/opentelemetry-operator`, chart **~0.119.0** (operator image
  ~0.154.0, 2026-07). Installs the `OpenTelemetryCollector` and `Instrumentation` CRDs.
- **CRDs:** `OpenTelemetryCollector` (the pipeline) and `Instrumentation` (zero-code
  auto-instrumentation injected into app pods). Source:
  https://opentelemetry.io/docs/platforms/kubernetes/operator/

### Collector deployment modes

```
Rank  Mode         Use for
1.    DaemonSet    node-level log/metric collection (one per node)   <- logs/host metrics
2.    Deployment   cluster-level aggregation / gateway (OTLP ingest) <- app traces/metrics
3.    Sidecar      per-pod, high-fidelity app traces (opt-in)
```

**Decision:** a **DaemonSet** collector (scrapes node logs + host metrics) + a **Deployment**
gateway collector (receives OTLP from apps, fans out to backends). Two OpenTelemetryCollector CRs.

### The pipeline (receive OTLP → export to each backend)

```yaml
# gitops/apps/otel-collector/collector.yaml  (sync wave 3 — needs operator CRD)
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata: { name: gateway, namespace: observability }
spec:
  mode: deployment
  config:
    receivers:
      otlp:
        protocols: { grpc: {}, http: {} }        # apps send OTLP here
    exporters:
      # METRICS -> Prometheus (via Prometheus remote-write receiver or scrape)
      prometheusremotewrite:
        endpoint: http://prometheus-operated.monitoring.svc:9090/api/v1/write
      # LOGS -> Loki native OTLP endpoint (otlphttp; the loki exporter is deprecated)
      otlphttp/loki:
        endpoint: http://loki-gateway.logging.svc.cluster.local/otlp
      # TRACES -> Tempo (OUT OF SCOPE here; this is where they'd go)
      # otlp/tempo: { endpoint: tempo.tracing.svc:4317 }
    service:
      pipelines:
        metrics: { receivers: [otlp], exporters: [prometheusremotewrite] }
        logs:    { receivers: [otlp], exporters: [otlphttp/loki] }
        # traces: { receivers: [otlp], exporters: [otlp/tempo] }
```

Key 2026 correctness note: export logs to Loki with the **`otlphttp`** exporter pointed at Loki's
native OTLP path — NOT the old dedicated `loki` exporter, which is deprecated. Source:
https://oneuptime.com/blog/post/2026-02-06-opentelemetry-logs-grafana-loki-collector/view

### Auto-instrumentation (zero-code app traces)

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata: { name: default, namespace: observability }
spec:
  exporter: { endpoint: http://gateway-collector.observability.svc:4317 }
  propagators: [tracecontext, baggage]
# Apps opt in with an annotation, e.g.:
#   instrumentation.opentelemetry.io/inject-python: "true"
```

---

## 5. Is Alloy replacing the OTel Collector? (2026 landscape)

Short answer: **no — they coexist.** Clarification:
- **Grafana Alloy** replaces **Promtail** (and Grafana Agent) as Grafana's own telemetry
  collector. It CAN collect metrics/logs/traces and speaks OTLP.
- **OTel Collector** is the vendor-neutral CNCF collector.
- For a portfolio that lists "OpenTelemetry" as a headline skill, standardize on the **OTel
  Collector** as the pipeline spine and mention Alloy as the Grafana-native alternative. Don't run
  both — pick one log/telemetry agent to keep the node footprint (and cost) down.

```
Old stack (pre-2025)         Golden 2026 stack
--------------------         --------------------------------
Promtail  -> Loki            OTel Collector (otlphttp) -> Loki /otlp/v1/logs
Prometheus scrape only       OTel Collector -> Prometheus remote-write (+ scrape)
(no unified traces)          OTel Collector + Instrumentation CRD -> traces
```

---

## Sources

- kube-prometheus-stack releases (87.16.1) — https://github.com/prometheus-community/helm-charts/releases
- Loki deployment modes — https://grafana.com/docs/loki/latest/get-started/deployment-modes/
- Loki S3 + Pod Identity request — https://github.com/grafana/loki/issues/12624
- Promtail deprecated -> Alloy (ADR) — https://docs-bigbang.dso.mil/latest/docs/adrs/0004-alloy-replacing-promtail
- OTel Operator for Kubernetes — https://opentelemetry.io/docs/platforms/kubernetes/operator/
- OTel logs -> Loki via otlphttp — https://oneuptime.com/blog/post/2026-02-06-opentelemetry-logs-grafana-loki-collector/view
- OTel Operator Helm chart (AWS blog) — https://aws.amazon.com/blogs/opensource/building-a-helm-chart-for-deploying-the-opentelemetry-operator
