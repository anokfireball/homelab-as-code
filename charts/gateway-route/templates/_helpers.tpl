{{/* charts/gateway-route/templates/_helpers.tpl */}}
{{- define "gateway-route.namespace" -}}
{{- .Values.namespace | default .Release.Namespace -}}
{{- end -}}

{{/*
Common labels applied to every resource this chart creates. Enables
`kubectl get certificate,listenerset,referencegrant,httproute -A \
  -l app.kubernetes.io/name=gateway-route` to find everything a
gateway-route release owns, across all per-service HelmReleases that
instantiate this chart.
*/}}
{{- define "gateway-route.labels" -}}
app.kubernetes.io/name: gateway-route
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
