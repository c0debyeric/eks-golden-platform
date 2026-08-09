{{/*
Shared naming and label helpers.
*/}}

{{- define "mcp-backend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcp-backend.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels. These land in Deployment.spec.selector, which is IMMUTABLE after
creation, so they must never include anything volatile (chart version, image tag,
release revision). A helm.sh/chart label in here would make every chart bump a
failed upgrade: "field is immutable".
*/}}
{{- define "mcp-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-backend.name" . }}
{{- end -}}

{{- define "mcp-backend.labels" -}}
{{ include "mcp-backend.selectorLabels" . }}
app.kubernetes.io/component: backend
app.kubernetes.io/part-of: eks-golden-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.environment }}
app.kubernetes.io/instance: {{ printf "%s-%s" (include "mcp-backend.name" .) .Values.environment }}
environment: {{ .Values.environment }}
{{- end }}
{{- end -}}

{{/*
Resolve the image reference, and FAIL THE RENDER if it is not pinned.

WHY fail rather than default: an unpinned image is not a cosmetic problem. The
kustomize setup this chart replaces used a PLACEHOLDER_IMAGE sentinel precisely
so a missing pin would be loud, and that sentinel still reached the cluster once
and stuck the Deployment in InvalidImageName. `required` moves the failure left,
to `helm template` in CI, where it costs nothing.

Digest wins when present: it is immutable by construction, so the artifact
promoted to prod is provably the bytes that were validated in stage. The tag is
still rendered alongside it for human readability.
*/}}
{{- define "mcp-backend.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $tag := required "image.tag must be pinned per environment (see gitops/apps/mcp-backend/values-<env>.yaml)" .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{ printf "%s:%s@%s" $repo $tag .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" $repo $tag }}
{{- end -}}
{{- end -}}

{{/*
Guard the OTel environment tag the same way. Without it, every environment
reports the same `deployment.environment` and Grafana cannot separate dev noise
from production signal — a silent data-quality failure, not a crash.
*/}}
{{- define "mcp-backend.environment" -}}
{{- required "environment must be set per environment values file" .Values.environment -}}
{{- end -}}
