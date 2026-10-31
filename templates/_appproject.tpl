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
  {{- /*
    A field that is present is rendered as written, even when empty: `[]` allows nothing, and a
    wrong type fails validation instead of widening to `*`. Only a missing or null field gets the
    default (or is left out). Not `default`/`with`: both treat an empty list or map as unset.
  */}}
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
