{{/*
Expand the name of the chart.
*/}}
{{- define "mcpo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mcpo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mcpo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "mcpo.labels" -}}
helm.sh/chart: {{ include "mcpo.chart" . }}
{{ include "mcpo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "mcpo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcpo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use.
*/}}
{{- define "mcpo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mcpo.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the ConfigMap containing mcp.json.
*/}}
{{- define "mcpo.configMapName" -}}
{{- default (printf "%s-config" (include "mcpo.fullname" .)) .Values.configMap.existingName }}
{{- end }}

{{/*
Create the name of the Secret containing mcp.json.
*/}}
{{- define "mcpo.configSecretName" -}}
{{- default (printf "%s-config" (include "mcpo.fullname" .)) .Values.configSecret.existingName }}
{{- end }}

{{/*
Create the name of the Secret containing the MCPO API key.
*/}}
{{- define "mcpo.apiKeySecretName" -}}
{{- default (printf "%s-api-key" (include "mcpo.fullname" .)) .Values.mcpo.apiKey.existingSecret }}
{{- end }}
