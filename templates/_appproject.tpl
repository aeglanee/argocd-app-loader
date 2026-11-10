{{- define "argocd-app-loader.appproject" -}}
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: {{ .name }}
  namespace: {{ default "argocd" .cluster.argocdNamespace }}
  annotations:
    {{- toYaml (merge (deepCopy (default dict .meta.annotations)) (dict "argocd.argoproj.io/sync-wave" (toString .wave))) | nindent 4 }}
  {{- with .meta.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  description: {{ .meta.description | default .name | quote }}
  sourceRepos:
    {{- toYaml (ternary .meta.sourceRepos (list "*") (not (kindIs "invalid" .meta.sourceRepos))) | nindent 4 }}
  destinations:
    {{- toYaml (ternary .meta.destinations (list (dict "namespace" "*" "server" "*")) (not (kindIs "invalid" .meta.destinations))) | nindent 4 }}
  clusterResourceWhitelist:
    {{- toYaml (ternary .meta.clusterResourceWhitelist (list (dict "group" "*" "kind" "*")) (not (kindIs "invalid" .meta.clusterResourceWhitelist))) | nindent 4 }}
  {{- if not (kindIs "invalid" .meta.clusterResourceBlacklist) }}
  clusterResourceBlacklist:
    {{- toYaml .meta.clusterResourceBlacklist | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" .meta.namespaceResourceWhitelist) }}
  namespaceResourceWhitelist:
    {{- toYaml .meta.namespaceResourceWhitelist | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" .meta.namespaceResourceBlacklist) }}
  namespaceResourceBlacklist:
    {{- toYaml .meta.namespaceResourceBlacklist | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" .meta.roles) }}
  roles:
    {{- toYaml .meta.roles | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" .meta.signatureKeys) }}
  signatureKeys:
    {{- toYaml .meta.signatureKeys | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" .meta.orphanedResources) }}
  orphanedResources:
    {{- toYaml .meta.orphanedResources | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" .meta.syncWindows) }}
  syncWindows:
    {{- toYaml .meta.syncWindows | nindent 4 }}
  {{- end }}
{{- end -}}
