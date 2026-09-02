{{/*
Expand the name of the chart.
*/}}
{{- define "mirrorcal-push.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mirrorcal-push.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mirrorcal-push.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "mirrorcal-push.labels" -}}
helm.sh/chart: {{ include "mirrorcal-push.chart" . }}
{{ include "mirrorcal-push.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "mirrorcal-push.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mirrorcal-push.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
The image tag to run: an explicit override, or the chart's own appVersion.
*/}}
{{- define "mirrorcal-push.imageTag" -}}
{{- .Values.image.tag | default .Chart.AppVersion -}}
{{- end -}}

{{/*
Name of the Secret holding the APNs auth key — either a pre-existing one the installer
points us at, or the one this chart creates from apns.authKey.value.
*/}}
{{- define "mirrorcal-push.authKeySecretName" -}}
{{- .Values.apns.authKey.existingSecret | default (printf "%s-apns-key" (include "mirrorcal-push.fullname" .)) -}}
{{- end -}}

{{/*
Name of the Secret holding the registration shared secret — same existingSecret-or-created
shape as the auth key above.
*/}}
{{- define "mirrorcal-push.sharedSecretSecretName" -}}
{{- .Values.registration.sharedSecret.existingSecret | default (printf "%s-registration-secret" (include "mirrorcal-push.fullname" .)) -}}
{{- end -}}
