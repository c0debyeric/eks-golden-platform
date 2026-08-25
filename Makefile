# EKS Golden Platform — lifecycle automation.
# `make up`   provisions the platform + bootstraps ArgoCD (which syncs the rest from Git).
# `make down` destroys everything (~$0); Terraform state (S3), Loki chunks and Tempo traces (S3) survive.
#
# Requires: terraform >= 1.15, awscli v2, kubectl, helm, and AWS creds in the environment.

TF        := terraform
TF_DIR    := terraform
REGION    ?= us-east-1
CLUSTER   ?= eks-golden
# Local port `otel-status` forwards the collector's self-metrics to. Overridable
# because 8888 is a common local-dev collision.
OTEL_PORT ?= 18888

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: init
init: ## terraform init with the S3 backend (copy backend.hcl.example -> backend.hcl first)
	cd $(TF_DIR) && $(TF) init -backend-config=backend.hcl

.PHONY: fmt
fmt: ## terraform fmt -check (CI gate)
	cd $(TF_DIR) && $(TF) fmt -check -recursive

.PHONY: validate
validate: ## terraform validate (syntax + provider schema; no cloud calls)
	cd $(TF_DIR) && $(TF) validate

.PHONY: plan
plan: ## terraform plan
	cd $(TF_DIR) && $(TF) plan

.PHONY: up
up: ## Provision platform + bootstrap ArgoCD, then wait for the app-of-apps to sync
	cd $(TF_DIR) && $(TF) apply -auto-approve
	@echo ">> Updating kubeconfig..."
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)
	@echo ">> ArgoCD is bootstrapping the stack. Watch with: make status"

.PHONY: down
down: ## Destroy EVERYTHING (~$0). S3 tf-state + Loki/Tempo telemetry are retained.
	cd $(TF_DIR) && $(TF) destroy -auto-approve

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

.PHONY: status
status: ## Show ArgoCD Applications + node/pod health
	@kubectl get applications -n argocd 2>/dev/null || echo "ArgoCD not ready yet"
	@kubectl get nodes
	@kubectl get pods -A | grep -E 'argocd|monitoring|logging|tracing|observability|external-secrets' || true

.PHONY: argocd-password
argocd-password: ## Print the initial ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d && echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:8080
	kubectl port-forward svc/argocd-server -n argocd 8080:443

.PHONY: grafana-ui
grafana-ui: ## Port-forward Grafana to http://localhost:3000 (dashboards, logs, traces)
	@echo ">> http://localhost:3000  — user/password via: make grafana-password"
	kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80

.PHONY: grafana-password
grafana-password: ## Print the Grafana admin credentials (materialised by External Secrets)
	@kubectl -n monitoring get secret grafana-admin-credentials \
		-o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d && echo " (user)" || \
		echo "Secret not ready — check the External Secrets app and eks-golden/grafana in Secrets Manager."
	@kubectl -n monitoring get secret grafana-admin-credentials \
		-o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d && echo " (password)"

.PHONY: otel-status
otel-status: ## Is telemetry actually flowing? (collector pods + per-signal throughput)
	@echo ">> Collectors"
	@kubectl get pods -n observability -l app.kubernetes.io/managed-by=opentelemetry-operator 2>/dev/null || true
	@printf '\n>> Accepted vs exported per signal\n'
	@printf '   both sides non-zero  = that signal is live\n'
	@printf '   send_failed climbing = the BACKEND is down, not the collector\n\n'
	@# PORT-FORWARD, NOT `kubectl exec`. This previously shelled into the collector and
	@# ran `wget`, which cannot work: the collector image
	@# (otel/opentelemetry-collector-contrib) is DISTROLESS -- no shell, no wget, no curl.
	@# Every invocation therefore fell through to the "could not read" branch, so the one
	@# target whose entire job is proving telemetry is flowing silently proved nothing.
	@# The operator already exposes these metrics as a Service; forward that instead.
	@set -e; \
	kubectl port-forward -n observability svc/gateway-collector-monitoring \
		$(OTEL_PORT):8888 >/dev/null 2>&1 & \
	pf=$$!; \
	trap 'kill $$pf 2>/dev/null || true' EXIT INT TERM; \
	ready=""; \
	for _ in $$(seq 1 20); do \
		if curl -sf "http://127.0.0.1:$(OTEL_PORT)/metrics" >/dev/null 2>&1; then ready=1; break; fi; \
		sleep 1; \
	done; \
	if [ -z "$$ready" ]; then \
		echo "Could not reach the gateway collector's metrics endpoint."; \
		echo "Check: kubectl get pods -n observability -l app.kubernetes.io/name=gateway-collector"; \
		exit 1; \
	fi; \
	curl -s "http://127.0.0.1:$(OTEL_PORT)/metrics" | \
		grep -E '^otelcol_(receiver_accepted|exporter_sent|exporter_send_failed)_(spans|metric_points|log_records)' | \
		sort || echo "Collector is up but exported no per-signal counters yet."

.PHONY: rds-info
rds-info: ## Show RDS endpoints + master-secret ARN (only if create_rds=true)
	@cd $(TF_DIR) && $(TF) output rds_primary_endpoint 2>/dev/null && \
		$(TF) output rds_replica_endpoints 2>/dev/null && \
		$(TF) output rds_master_secret_arn 2>/dev/null || \
		echo "No RDS outputs — set create_rds=true in terraform.tfvars and 'make up'."

.PHONY: db-password
db-password: ## Print the RDS master password from Secrets Manager
	@aws secretsmanager get-secret-value --region $(REGION) \
		--secret-id eks-golden/rds-master \
		--query SecretString --output text | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['password'])"

.PHONY: app-url
app-url: ## Print the public URL of the dev frontend (ALB Ingress)
	@host=$$(kubectl get ingress mcp-frontend -n mcp-dev \
		-o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	if [ -n "$$host" ]; then echo "http://$$host"; else \
		echo "No ALB yet — the ingress is dev-only and takes ~2 min to provision."; fi

.PHONY: app-status
app-status: ## Show the app workloads across all three environments
	@for ns in mcp-dev mcp-stage mcp-prod; do \
		echo ">> $$ns"; \
		kubectl get deploy,pods -n $$ns --no-headers 2>/dev/null || echo "   (namespace absent)"; \
	done
	@printf '\n>> Image actually running per environment\n'
	@kubectl get pods -A -l app.kubernetes.io/part-of=eks-golden-platform \
		-o custom-columns='NS:.metadata.namespace,POD:.metadata.name,IMAGE:.spec.containers[0].image' \
		--no-headers 2>/dev/null || true

.PHONY: app-render
app-render: ## Render both charts for every environment exactly as ArgoCD will (offline)
	@for app in mcp-backend mcp-frontend; do \
		for env in dev stage prod; do \
			echo ">> $$app/$$env"; \
			helm template $$app charts/$$app \
				-f gitops/apps/$$app/values-$$env.yaml >/dev/null || exit 1; \
		done; \
	done
	@echo "All 6 renders OK"
	@python3 scripts/helm_values_gate.py charts/mcp-backend gitops/apps/mcp-backend
	@python3 scripts/helm_values_gate.py charts/mcp-frontend gitops/apps/mcp-frontend
