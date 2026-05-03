{{- /*
  argocd-app-loader.application — render one Argo CD Application from a metadata dict.

  Permissive: any field declared in the input dict's appMeta passes through
  via toYaml, mirroring the style of argoproj/argo-helm/charts/argocd-apps.

  Expected input dict keys:
    name      : app folder name (also default release name)
    group     : group folder name (also default project)
    appMeta   : parsed app.yaml content (may carry any Application spec field)
    groupMeta : parsed _group.yaml content (fallbacks for project/etc)
    global    : .Values.global from the consumer chart
    Values    : full consumer .Values (so tpl works against it)
*/ -}}
{{- define "argocd-app-loader.application" -}}
{{- $defaultRepo := ternary .global.localGitRepo .global.remoteGitRepo (default false .global.useLocalGit) -}}
{{- $project := .appMeta.project | default .groupMeta.project | default .group -}}
{{- $namespace := .appMeta.namespace | default .name -}}
{{- $releaseName := .appMeta.releaseName | default .name -}}
{{- $base := default "" .global.repoBasePath -}}
{{- $appPath := .appMeta.path -}}
{{- if not $appPath -}}
  {{- if $base -}}
    {{- $appPath = printf "%s/apps/%s/%s" $base .group .name -}}
  {{- else -}}
    {{- $appPath = printf "apps/%s/%s" .group .name -}}
  {{- end -}}
{{- end -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: {{ default "argocd" .global.argocdNamespace }}
  {{- with .appMeta.annotations }}
  annotations:
    {{- range $k, $v := . }}
    {{ $k }}: {{ tpl (toString $v) $.Root | quote }}
    {{- end }}
  {{- else }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ .appMeta.wave | default 0 | quote }}
  {{- end }}
  {{- with .appMeta.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  finalizers:
    {{- toYaml (.appMeta.finalizers | default (list "resources-finalizer.argocd.argoproj.io")) | nindent 4 }}
spec:
  project: {{ tpl (toString $project) .Root | quote }}
  destination:
    server: {{ default "https://kubernetes.default.svc" .global.clusterServer }}
    namespace: {{ $namespace }}
  {{- with .appMeta.sources }}
  sources:
    {{- toYaml . | nindent 4 }}
  {{- else }}
  source:
    repoURL: {{ tpl (toString (.appMeta.repoURL | default $defaultRepo)) .Root | quote }}
    targetRevision: {{ .appMeta.targetRevision | default .global.targetRevision | default "HEAD" }}
    path: {{ $appPath }}
    helm:
      releaseName: {{ $releaseName }}
      # Cascade cluster-wide globals into the wrapper chart's release.
      # Helm's subchart `global:` propagation forwards these to the upstream
      # chart automatically, so .Values.global resolves at every layer.
      valuesObject:
        global:
{{ toYaml .global | indent 10 }}
      {{- with .appMeta.helm }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
  {{- end }}
  syncPolicy:
    {{- $defaultSyncPolicy := dict
        "automated" (dict "prune" true "selfHeal" true)
        "retry" (dict
          "limit" 10
          "backoff" (dict
            "duration" "30s"
            "factor" 2
            "maxDuration" "5m"))
        "syncOptions" (concat
          (ternary (list "CreateNamespace=true") (list) (default false .appMeta.createNamespace))
          (.appMeta.syncOptions | default list)) -}}
    {{- toYaml (.appMeta.syncPolicy | default $defaultSyncPolicy) | nindent 4 }}
  {{- with .appMeta.ignoreDifferences }}
  ignoreDifferences:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .appMeta.info }}
  info:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .appMeta.revisionHistoryLimit }}
  revisionHistoryLimit: {{ . }}
  {{- end }}
{{- end -}}
