{{- /*
  argocd-apps.appproject — render one Argo CD AppProject from a metadata dict.

  Permissive: any AppProject spec field declared in meta passes through via
  toYaml. Sensible homelab defaults applied for fields not declared.

  Expected input dict keys:
    name   : project name (= group folder name by convention)
    meta   : parsed _group.yaml content (may carry any AppProject spec field)
    global : .Values.global from the consumer chart
    Values : full consumer .Values (so tpl works against it)
*/ -}}
{{- define "argocd-apps.appproject" -}}
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: {{ .name }}
  namespace: {{ default "argocd" .global.argocdNamespace }}
  {{- with .meta.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .meta.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  description: {{ .meta.description | default .name | quote }}
  sourceRepos:
    {{- toYaml (.meta.sourceRepos | default (list "*")) | nindent 4 }}
  destinations:
    {{- toYaml (.meta.destinations | default (list (dict "namespace" "*" "server" "*"))) | nindent 4 }}
  clusterResourceWhitelist:
    {{- toYaml (.meta.clusterResourceWhitelist | default (list (dict "group" "*" "kind" "*"))) | nindent 4 }}
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
