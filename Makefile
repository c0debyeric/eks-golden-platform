# EKS Golden Platform — lifecycle automation.
# `make up`   provisions the platform + bootstraps ArgoCD (which syncs the rest from Git).
# `make down` destroys everything (~$0); Terraform state (S3), Loki chunks and Tempo traces (S3) survive.
#
# Requires: terraform >= 1.15, awscli v2, kubectl, helm, and AWS creds in the environment.

TF        := terraform
TF_DIR    := terraform
REGION    ?= us-east-1
CLUSTER   ?= eks-golden

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
	@echo "\n>> Accepted vs exported (non-zero on both sides means the pipeline is live)"
	@kubectl exec -n observability deploy/gateway-collector -- \
		wget -qO- http://localhost:8888/metrics 2>/dev/null | \
		grep -E '^otelcol_(receiver_accepted|exporter_sent|exporter_send_failed)_(spans|metric_points|log_records)' || \
		echo "Could not read collector telemetry — is the gateway running?"

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
