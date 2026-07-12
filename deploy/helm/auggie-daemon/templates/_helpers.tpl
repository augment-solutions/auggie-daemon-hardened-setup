{{/* Chart naming helpers. */}}
{{- define "auggie-daemon.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "auggie-daemon.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "auggie-daemon.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "auggie-daemon.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "auggie-daemon.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "auggie-daemon.selectorLabels" -}}
app.kubernetes.io/name: {{ include "auggie-daemon.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "auggie-daemon.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "auggie-daemon.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "auggie-daemon.headlessServiceName" -}}
{{- printf "%s-headless" (include "auggie-daemon.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "auggie-daemon.image" -}}
{{- $repo := required "image.repository is required; supply a private Rocky Linux 8-compatible OCI image" .Values.image.repository -}}
{{- if eq (.Values.image.tag | lower) "latest" -}}{{- fail "image.tag=latest is not allowed; use an immutable tag or digest" -}}{{- end -}}
{{- if and .Values.image.tag .Values.image.digest -}}{{- fail "set only one of image.tag or image.digest" -}}{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (required "image.tag or image.digest is required; do not deploy an unpinned latest image" .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{- define "auggie-daemon.bootstrapImage" -}}
{{- $repo := required "bootstrap.bootstrapImage.repository is required for bootstrapImage mode; no hosted bootstrap image is assumed" .Values.bootstrap.bootstrapImage.repository -}}
{{- if eq (.Values.bootstrap.bootstrapImage.tag | lower) "latest" -}}{{- fail "bootstrap.bootstrapImage.tag=latest is not allowed; use an immutable tag or digest" -}}{{- end -}}
{{- if and .Values.bootstrap.bootstrapImage.tag .Values.bootstrap.bootstrapImage.digest -}}{{- fail "set only one of bootstrap.bootstrapImage.tag or bootstrap.bootstrapImage.digest" -}}{{- end -}}
{{- if .Values.bootstrap.bootstrapImage.digest -}}
{{- printf "%s@%s" $repo .Values.bootstrap.bootstrapImage.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (required "bootstrap.bootstrapImage.tag or digest is required for bootstrapImage mode" .Values.bootstrap.bootstrapImage.tag) -}}
{{- end -}}
{{- end -}}

{{- define "auggie-daemon.secretProviderClassName" -}}
{{- if .Values.credentials.secretProviderClass.create -}}
{{- default (include "auggie-daemon.fullname" .) .Values.credentials.secretProviderClass.name -}}
{{- else -}}
{{- required "credentials.secretProviderClass.existingName is required when SecretProviderClass creation is disabled" .Values.credentials.secretProviderClass.existingName -}}
{{- end -}}
{{- end -}}

{{- define "auggie-daemon.auggieBinary" -}}
{{- if eq .Values.bootstrap.mode "preinstalled" -}}
auggie
{{- else if eq .Values.bootstrap.mode "bootstrapImage" -}}
{{- printf "%s/npm/bin/auggie" .Values.bootstrap.runtimeMountPath -}}
{{- else -}}
{{- printf "%s/bin/auggie" .Values.bootstrap.runtimeMountPath -}}
{{- end -}}
{{- end -}}

{{- define "auggie-daemon.sessionPath" -}}
{{- printf "%s/%s" (.Values.credentials.mountPath | trimSuffix "/") .Values.credentials.sessionFile -}}
{{- end -}}

{{- define "auggie-daemon.configChecksum" -}}
{{- dict "daemon" .Values.daemon "bootstrap" .Values.bootstrap "workspace" .Values.workspace "credentials" .Values.credentials | toJson | sha256sum -}}
{{- end -}}

{{/* Fail early for unsafe or contradictory combinations. */}}
{{- define "auggie-daemon.validate" -}}
{{- if not (has .Values.platform.mode (list "generic" "gkeStandard" "gkeAutopilot")) -}}
{{- fail "platform.mode must be generic, gkeStandard, or gkeAutopilot" -}}
{{- end -}}
{{- if not (has .Values.bootstrap.mode (list "bootstrapImage" "runtimeNpm" "preinstalled")) -}}
{{- fail "bootstrap.mode must be bootstrapImage, runtimeNpm, or preinstalled" -}}
{{- end -}}
{{- if ne .Values.bootstrap.auggieVersion "0.32.0" -}}
{{- fail "bootstrap.auggieVersion must be exactly 0.32.0 for this chart release" -}}
{{- end -}}
{{- if eq .Values.bootstrap.mode "bootstrapImage" -}}
{{- include "auggie-daemon.bootstrapImage" . -}}
{{- end -}}
{{- if not (has .Values.workspace.mode (list "ephemeral" "persistent" "image")) -}}
{{- fail "workspace.mode must be ephemeral, persistent, or image" -}}
{{- end -}}
{{- if and (eq .Values.workspace.mode "image") (empty .Values.workspace.image.sourcePath) -}}
{{- fail "workspace.image.sourcePath is required when workspace.mode=image" -}}
{{- end -}}
{{- if and (eq .Values.workspace.mode "image") (not (hasPrefix "/" .Values.workspace.image.sourcePath)) -}}
{{- fail "workspace.image.sourcePath must be an absolute path" -}}
{{- end -}}
{{- if and (eq .Values.workspace.mode "image") (hasPrefix "/var/run/augment-workspace-target" .Values.workspace.image.sourcePath) -}}
{{- fail "workspace.image.sourcePath must not use the chart's internal workspace target path" -}}
{{- end -}}
{{- if and (eq .Values.workspace.mode "persistent") (empty .Values.workspace.persistence.size) -}}
{{- fail "workspace.persistence.size is required when workspace.mode=persistent" -}}
{{- end -}}
{{- if or (eq .Values.workspace.mountPath .Values.credentials.mountPath) (eq .Values.workspace.mountPath .Values.home.mountPath) (eq .Values.credentials.mountPath .Values.home.mountPath) -}}
{{- fail "workspace.mountPath, credentials.mountPath, and home.mountPath must be distinct" -}}
{{- end -}}
{{- if or (eq .Values.workspace.mountPath "/tmp") (eq .Values.credentials.mountPath "/tmp") (eq .Values.home.mountPath "/tmp") -}}
{{- fail "workspace.mountPath, credentials.mountPath, and home.mountPath must not be /tmp" -}}
{{- end -}}
{{- if and (ne .Values.bootstrap.mode "preinstalled") (or (eq .Values.bootstrap.runtimeMountPath .Values.workspace.mountPath) (eq .Values.bootstrap.runtimeMountPath .Values.credentials.mountPath) (eq .Values.bootstrap.runtimeMountPath .Values.home.mountPath) (eq .Values.bootstrap.runtimeMountPath "/tmp")) -}}
{{- fail "bootstrap.runtimeMountPath must not overlap another explicit mount path" -}}
{{- end -}}
{{- if hasKey .Values.podAnnotations "checksum/config" -}}
{{- fail "podAnnotations must not override the reserved checksum/config annotation" -}}
{{- end -}}
{{- if or (hasKey .Values.podLabels "app.kubernetes.io/name") (hasKey .Values.podLabels "app.kubernetes.io/instance") -}}
{{- fail "podLabels must not override StatefulSet selector labels" -}}
{{- end -}}
{{- if empty .Values.daemon.poolId -}}
{{- fail "daemon.poolId is required" -}}
{{- end -}}
{{- if or (eq .Values.credentials.sessionFile ".") (eq .Values.credentials.sessionFile "..") -}}
{{- fail "credentials.sessionFile must be a safe file name" -}}
{{- end -}}
{{- if eq .Values.credentials.mode "secretProviderClass" -}}
  {{- if .Values.credentials.secretProviderClass.create -}}
    {{- if empty .Values.credentials.secretProviderClass.secrets -}}
      {{- fail "credentials.secretProviderClass.secrets must contain at least one Secret Manager reference when create=true" -}}
    {{- end -}}
    {{- $sessionFound := false -}}
    {{- range .Values.credentials.secretProviderClass.secrets -}}
      {{- if or (empty .resourceName) (empty .path) -}}
        {{- fail "each credentials.secretProviderClass.secrets item requires resourceName and path" -}}
      {{- end -}}
      {{- if eq .path $.Values.credentials.sessionFile -}}{{- $sessionFound = true -}}{{- end -}}
    {{- end -}}
    {{- if not $sessionFound -}}
      {{- fail "one SecretProviderClass secret path must equal credentials.sessionFile" -}}
    {{- end -}}
  {{- else -}}
    {{- required "credentials.secretProviderClass.existingName is required when create=false" .Values.credentials.secretProviderClass.existingName -}}
  {{- end -}}
{{- else if eq .Values.credentials.mode "kubernetesSecret" -}}
  {{- if not .Values.credentials.kubernetesSecret.acknowledgeRisk -}}
    {{- fail "Kubernetes Secret fallback is discouraged; set credentials.kubernetesSecret.acknowledgeRisk=true to explicitly accept the risk" -}}
  {{- end -}}
  {{- required "credentials.kubernetesSecret.existingSecret is required for Kubernetes Secret fallback" .Values.credentials.kubernetesSecret.existingSecret -}}
  {{- required "credentials.kubernetesSecret.key is required for Kubernetes Secret fallback" .Values.credentials.kubernetesSecret.key -}}
{{- else -}}
{{- fail "credentials.mode must be secretProviderClass or kubernetesSecret" -}}
{{- end -}}
{{- if and (ne .Values.podDisruptionBudget.minAvailable nil) (ne .Values.podDisruptionBudget.maxUnavailable nil) -}}
{{- fail "set only one of podDisruptionBudget.minAvailable or maxUnavailable" -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (gt .Values.autoscaling.minReplicas .Values.autoscaling.maxReplicas) -}}
{{- fail "autoscaling.maxReplicas must be greater than or equal to minReplicas" -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (eq .Values.autoscaling.targetCPUUtilizationPercentage nil) (eq .Values.autoscaling.targetMemoryUtilizationPercentage nil) -}}
{{- fail "autoscaling requires at least one CPU or memory utilization target" -}}
{{- end -}}
{{- include "auggie-daemon.image" . -}}
{{- end -}}