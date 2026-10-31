{{- /*
  argocd-app-loader.appproject — render one Argo CD AppProject from a metadata dict.

  Permissive: any AppProject spec field declared in meta passes through via
  toYaml. Sensible defaults applied for fields not declared.

  Expected input dict keys:
    name   : project name (= group folder name by convention)
    meta   : parsed _group.yaml content (may carry any AppProject spec field)
    cluster : .Values.cluster from the consumer chart
    Values : full consumer .Values (so tpl works against it)
*/ -}}
{{- define "argocd-app-loader.appproject" -}}
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: {{ .name }}
  namespace: {{ default "argocd" .cluster.argocdNamespace }}
  {{- with .meta.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- /* kindIs, not `default`: an explicit `[]` (allow nothing) must not widen to `*`. */}}
  description: {{ .meta.description | default .name | quote }}
  sourceRepos:
    {{- toYaml (ternary .meta.sourceRepos (list "*") (kindIs "slice" .meta.sourceRepos)) | nindent 4 }}
  destinations:
    {{- toYaml (ternary .meta.destinations (list (dict "namespace" "*" "server" "*")) (kindIs "slice" .meta.destinations)) | nindent 4 }}
  clusterResourceWhitelist:
    {{- toYaml (ternary .meta.clusterResourceWhitelist (list (dict "group" "*" "kind" "*")) (kindIs "slice" .meta.clusterResourceWhitelist)) | nindent 4 }}
  {{- with .meta.clusterResourceBlacklist }}
  clusterResourceBlacklist:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.namespaceResourceWhitelist }}
  namespaceResourceWhitelist:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.namespaceResourceBlacklist }}
  namespaceResourceBlacklist:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.roles }}
  roles:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.signatureKeys }}
  signatureKeys:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.orphanedResources }}
  orphanedResources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.syncWindows }}
  syncWindows:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
