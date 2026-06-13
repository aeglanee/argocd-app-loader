{{- /*
  argocd-app-loader.application — render one Argo CD Application from a metadata dict.

  Permissive: any field declared in the input dict's appMeta passes through
  via toYaml, mirroring the style of argoproj/argo-helm/charts/argocd-apps.

  Expected input dict keys:
    name      : app folder name (also default release name)
    group     : group folder name (also default project)
    appMeta   : parsed app.yaml content (may carry any Application spec field)
    groupMeta : parsed _group.yaml content (fallbacks for project/etc)
    cluster   : .Values.cluster from the consumer chart
    Values    : full consumer .Values (so tpl works against it)
*/ -}}
{{- define "argocd-app-loader.application" -}}
{{- $defaultRepo := ternary .cluster.localGitRepo .cluster.remoteGitRepo (default false .cluster.useLocalGit) -}}
{{- $project := .appMeta.project | default .groupMeta.project | default .group -}}
{{- $namespace := .appMeta.namespace | default .name -}}
{{- $releaseName := .appMeta.releaseName | default .name -}}
{{- $base := default "" .cluster.repoBasePath -}}
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
  namespace: {{ default "argocd" .cluster.argocdNamespace }}
  {{- /*
    Build the annotation map: any custom annotations (tpl-rendered against the
    consumer context), then ALWAYS set the sync-wave from .appMeta.wave so it is
    never dropped when custom annotations are also present. `wave` is the
    canonical ordering source; to set a custom sync-wave, use the `wave` field.
  */ -}}
  {{- $annotations := dict -}}
  {{- range $k, $v := (.appMeta.annotations | default dict) -}}
    {{- $_ := set $annotations $k (tpl (toString $v) $.Root) -}}
  {{- end -}}
  {{- $_ := set $annotations "argocd.argoproj.io/sync-wave" (toString (.appMeta.wave | default 0)) }}
  annotations:
    {{- range $k, $v := $annotations }}
    {{ $k }}: {{ $v | quote }}
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
    server: {{ default "https://kubernetes.default.svc" .cluster.clusterServer }}
    namespace: {{ $namespace }}
  {{- if .appMeta.chart }}
  {{- /*
    v2 multisource — the upstream chart is source A (repoURL computed from chart.oci|.http +
    useLocalRegistry + cluster.ociRepos), and the app dir's own Chart.yaml/templates (if present,
    with NO dependency on this upstream) is source B, the local chart. Values split: wrapperValues
    `chart:` → A, everything else → B.
  */ -}}
  {{- $c := .appMeta.chart -}}
  {{- $chartValues := default dict (get (default dict .wrapperValues) "chart") -}}
  {{- $localValues := omit (default dict .wrapperValues) "chart" -}}
  {{- $repoA := "" -}}
  {{- if $c.oci -}}
    {{- $segs := splitList "/" (toString $c.oci) -}}
    {{- $proxy := index (default dict .cluster.ociRepos) (first $segs) -}}
    {{- $repoA = ternary (printf "oci://harbor.%s/%s/%s" .cluster.domain $proxy (join "/" (rest $segs))) (printf "oci://%s" (toString $c.oci)) (default false .cluster.useLocalRegistry) -}}
  {{- else -}}
    {{- $repoA = toString $c.http -}}
  {{- end }}
  sources:
    - repoURL: {{ tpl $repoA .Root | quote }}
      chart: {{ $c.name | quote }}
      targetRevision: {{ toString $c.version | quote }}
      helm:
        releaseName: {{ $releaseName }}
        valuesObject:
{{ toYaml (mustMergeOverwrite (deepCopy $chartValues) (dict "cluster" .cluster)) | indent 10 }}
        {{- with .appMeta.helm }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- if .hasLocalChart }}
    - repoURL: {{ tpl (toString $defaultRepo) .Root | quote }}
      targetRevision: {{ .appMeta.targetRevision | default .cluster.targetRevision | default "HEAD" }}
      path: {{ $appPath }}
      helm:
        releaseName: {{ $releaseName }}
        valuesObject:
{{ toYaml (mustMergeOverwrite (deepCopy $localValues) (dict "cluster" .cluster)) | indent 10 }}
    {{- end }}
  {{- else if .appMeta.sources }}
  sources:
    {{- toYaml .appMeta.sources | nindent 4 }}
  {{- else }}
  source:
    repoURL: {{ tpl (toString (.appMeta.repoURL | default $defaultRepo)) .Root | quote }}
    targetRevision: {{ .appMeta.targetRevision | default .cluster.targetRevision | default "HEAD" }}
    path: {{ $appPath }}
    helm:
      releaseName: {{ $releaseName }}
      # Per-source value handling:
      #   - .wrapperValues: the wrapper's own values.yaml, already tpl-rendered
      #     against the consumer chart context by the loader so cross-cutting
      #     references like {{ .Values.cluster.domain }} resolve.
      #   - cluster: cluster identity/config, recursively overwritten on top so
      #     cluster identity always wins over per-app declarations. Injected
      #     under `cluster:` (NOT `global:`) so it cascades into THIS wrapper's
      #     own templates (as .Values.cluster.*) WITHOUT silently propagating
      #     into upstream subcharts via Helm's global mechanism — which would
      #     risk collisions with charts that read global.* (imageRegistry,
      #     storageClass, imagePullSecrets, ...). To deliberately feed an
      #     upstream chart a real Helm global, set `global:` explicitly in that
      #     wrapper's own values.
      # Both go through valuesObject so we deliver structured YAML rather than
      # a string blob — easier for ArgoCD to diff and for humans to read.
      valuesObject:
{{ toYaml (mustMergeOverwrite (deepCopy (default dict .wrapperValues)) (dict "cluster" .cluster)) | indent 8 }}
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
