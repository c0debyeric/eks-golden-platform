{{/*
Shared naming and label helpers. Mirrors charts/mcp-backend/templates/_helpers.tpl
deliberately — two workloads labelled two different ways breaks the Grafana
queries that select on app.kubernetes.io/part-of.
*/}}

{{- define "mcp-frontend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcp-frontend.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels only — Deployment.spec.selector is immutable, so nothing volatile
(chart version, image tag) may appear here.
*/}}
{{- define "mcp-frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-frontend.name" . }}
{{- end -}}

{{- define "mcp-frontend.labels" -}}
{{ include "mcp-frontend.selectorLabels" . }}
app.kubernetes.io/component: frontend
app.kubernetes.io/part-of: eks-golden-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.environment }}
app.kubernetes.io/instance: {{ printf "%s-%s" (include "mcp-frontend.name" .) .Values.environment }}
environment: {{ .Values.environment }}
{{- end }}
{{- end -}}

{{/*
Fail the render on an unpinned image rather than defaulting to something
plausible. See the equivalent helper in the backend chart for why.
*/}}
{{- define "mcp-frontend.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $tag := required "image.tag must be pinned per environment (see gitops/apps/mcp-frontend/values-<env>.yaml)" .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{ printf "%s:%s@%s" $repo $tag .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" $repo $tag }}
{{- end -}}
{{- end -}}

{{- define "mcp-frontend.environment" -}}
{{- required "environment must be set per environment values file" .Values.environment -}}
{{- end -}}

{{/*
The backend URL must be explicit per environment. Defaulting it would point the
wrong environment's UI at another environment's database — a cross-environment
data leak that produces no error at all, just wrong data.
*/}}
{{- define "mcp-frontend.backendUrl" -}}
{{- required "backend.url must be set per environment values file" .Values.backend.url -}}
{{- end -}}
