{{- /*
  argocd-app-loader.application — render one Argo CD Application from a metadata dict.

  Permissive: any field declared in the input dict's appMeta passes through
  via toYaml, mirroring the style of argoproj/argo-helm/charts/argocd-apps.

  Expected input dict keys:
    name      : app folder name (also default release name)
    group     : group folder name (also default project)
    appMeta   : parsed app.yaml content (may carry any Application spec field)
    groupMeta : parsed _group.yaml content (fallbacks for project/etc)
    appDir    : the app folder inside the consumer chart (<appsRoot>/<group>/<name>)
    hasLocalChart, hasKustomize : what the app folder holds
    cluster   : .Values.cluster from the consumer chart
    Values    : full consumer .Values (so tpl works against it)
*/ -}}
{{- define "argocd-app-loader.application" -}}
{{- /* Bound once: `range` rebinds the dot, so .cluster is not reachable inside the loops below. */ -}}
{{- $cluster := .cluster -}}
{{- $project := .appMeta.project | default .groupMeta.project | default .group -}}
{{- $namespace := .appMeta.namespace | default .name -}}
{{- $releaseName := .appMeta.releaseName | default .name -}}
{{- /*
  Where this chart's own files live: Helm's .Files can't tell where the chart sits in its repo, so
  the consumer says so in argocdAppLoader.source. Read only when an app has files of its own.
*/ -}}
{{- $own := default dict (get (default dict .Values.argocdAppLoader) "source") -}}
{{- $ownRepo := "" -}}
{{- if or .hasLocalChart .hasKustomize (not (or .appMeta.chart .appMeta.sources .appMeta.repoURL)) -}}
  {{- $ownRepo = tpl (toString (required (printf "argocd-app-loader: argocdAppLoader.source.repoURL is required: app %s has files of its own in this chart's repo (0.8's cluster.remoteGitRepo, localGitRepo and useLocalGit are no longer read)" .name) $own.repoURL)) .Root -}}
{{- end -}}
{{- $base := trimSuffix "/" (trimPrefix "./" (toString (default "" $own.path))) -}}
{{- $ownRevision := .appMeta.targetRevision | default $own.targetRevision | default "HEAD" -}}
{{- $appPath := .appMeta.path | default (ternary .appDir (printf "%s/%s" $base .appDir) (or (eq $base "") (eq $base "."))) -}}
{{- if .appMeta.repoURL -}}
  {{- /* Another repo: this chart's revision and folder layout mean nothing there. */ -}}
  {{- $ownRevision = .appMeta.targetRevision | default "HEAD" -}}
  {{- $appPath = required (printf "argocd-app-loader: app %s sets repoURL:, so it needs path: too (the folder in that repo)" .name) .appMeta.path -}}
{{- end -}}
{{- /* Pinned so the render doesn't depend on what the live cluster happens to have installed. */ -}}
{{- $pins := dict -}}
{{- with .cluster.kubeVersion -}}
  {{- if not (kindIs "string" .) -}}
    {{- fail (printf "argocd-app-loader: cluster.kubeVersion must be a string, so quote it (got %v, which YAML reads as a %s)" . (kindOf .)) -}}
  {{- end -}}
  {{- $_ := set $pins "kubeVersion" . -}}
{{- end -}}
{{- with .cluster.apiVersions }}{{ $_ := set $pins "apiVersions" . }}{{ end -}}
{{- /* An app's own helm: block wins over the pins (it is written after them, so drop them here). */ -}}
{{- $helmPins := deepCopy $pins -}}
{{- range $k := keys (default dict .appMeta.helm) }}{{ $_ := unset $helmPins $k }}{{ end -}}
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
  {{- /* Present is rendered as written (`[]` = none; a wrong type fails validation); missing or null
         gets the default. Not `default`: it treats an explicit `finalizers: []` as unset. */ -}}
  {{- with ternary .appMeta.finalizers (list "resources-finalizer.argocd.argoproj.io") (not (kindIs "invalid" .appMeta.finalizers)) }}
  finalizers:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  project: {{ tpl (toString $project) .Root | quote }}
  destination:
    server: {{ default "https://kubernetes.default.svc" .cluster.clusterServer }}
    namespace: {{ $namespace }}
  {{- if .appMeta.chart }}
  {{- /*
    Multisource — the upstream chart is source A (repoURL = chart.repo resolved through
    cluster.mirrors, see _mirror.tpl), and the app dir's own Chart.yaml/templates (if present,
    with NO dependency on this upstream) is source B, the local chart. Values split:
    wrapperValues `chart:` → A, everything else → B.
  */ -}}
  {{- $c := .appMeta.chart -}}
  {{- /* source A gets the `chart:` subtree of the wrapper values, source B the rest. */ -}}
  {{- $chartValues := default dict (get (default dict .wrapperValues) "chart") -}}
  {{- $localValues := omit (default dict .wrapperValues) "chart" -}}
  {{- $kind := include "argocd-app-loader.chartKind" $c -}}
  {{- $mirror := eq (include "argocd-app-loader.mirrorFlag" $c.mirror) "true" -}}
  {{- $version := toString (required (printf "argocd-app-loader: chart.version is required for app %s (git: the tag/ref)" .name) $c.version) }}
  sources:
    - repoURL: {{ include "argocd-app-loader.mirrorURL" (dict "url" $c.repo "kind" $kind "mirror" $mirror "cluster" .cluster "Root" .Root) | quote }}
      {{- if eq $kind "git" }}
      path: {{ $c.path | quote }}
      {{- else }}
      chart: {{ $c.name | quote }}
      {{- end }}
      targetRevision: {{ $version | quote }}
      helm:
        releaseName: {{ $releaseName }}
        valuesObject:
{{ toYaml $chartValues | indent 10 }}
        {{- with $helmPins }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- with .appMeta.helm }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- if .hasLocalChart }}
    {{- include "argocd-app-loader.ownChartSource" (dict "repoURL" $ownRepo "targetRevision" $ownRevision "path" $appPath "releaseName" $releaseName "values" $localValues "pins" $pins) | nindent 4 }}
    {{- end }}
  {{- else if .hasKustomize }}
  {{- /* Kustomize form: Kustomize renders kustomize/ (helmCharts: + patches:), the local chart the
         rest. Upstream values live in kustomize/, so a values `chart:` block has nowhere to go. */ -}}
  {{- if hasKey (default dict .wrapperValues) "chart" -}}
    {{- fail (printf "argocd-app-loader: app %s uses the Kustomize form, so its values (values file or cluster.overrides) can't have a chart: block; put the upstream chart's values in kustomize/ (helmCharts valuesFile or valuesInline)" .name) -}}
  {{- end -}}
  {{- if and .wrapperValues (not .hasLocalChart) -}}
    {{- fail (printf "argocd-app-loader: app %s has values but no Chart.yaml to take them; the Kustomize form's upstream values live in kustomize/" .name) -}}
  {{- end }}
  sources:
    - repoURL: {{ $ownRepo | quote }}
      targetRevision: {{ $ownRevision | quote }}
      path: {{ $appPath }}/kustomize
      {{- with $pins }}
      kustomize:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    {{- if .hasLocalChart }}
    {{- include "argocd-app-loader.ownChartSource" (dict "repoURL" $ownRepo "targetRevision" $ownRevision "path" $appPath "releaseName" $releaseName "values" (default dict .wrapperValues) "pins" $helmPins "helm" .appMeta.helm) | nindent 4 }}
    {{- end }}
  {{- else if .appMeta.sources }}
  {{- /* Verbatim multi-source passthrough — for apps that are not a Helm chart at all (raw
         upstream YAML, e.g. the Gateway API CRDs). Every field is emitted as written; the ONLY
         thing rewritten is repoURL (through cluster.mirrors, like a chart.repo), and a per-source
         `mirror: false` opt-out is consumed (not emitted). A source with `chart:` is a Helm
         source (oci:// or scheme-less = OCI, else an HTTP repo); anything else is git. */}}
  sources:
    {{- range $src := .appMeta.sources }}
    {{- $s := omit (deepCopy $src) "mirror" -}}
    {{- /* A Helm source (chart: or helm:) gets the pins too, unless it sets them itself. */ -}}
    {{- if and $pins (or $s.chart $s.helm) -}}
      {{- $_ := set $s "helm" (mustMergeOverwrite (deepCopy $pins) (default dict $s.helm)) -}}
    {{- end -}}
    {{- if $s.repoURL -}}
      {{- $u := toString $s.repoURL -}}
      {{- $k := "git" -}}
      {{- if $s.chart -}}
        {{- $k = ternary "oci" "helm" (or (hasPrefix "oci://" $u) (not (regexMatch "^https?://" $u))) -}}
      {{- end -}}
      {{- $_ := set $s "repoURL" (include "argocd-app-loader.mirrorURL" (dict "url" $u "kind" $k "mirror" (eq (include "argocd-app-loader.mirrorFlag" $src.mirror) "true") "cluster" $cluster "Root" $.Root)) -}}
    {{- end }}
    - {{ toYaml $s | nindent 6 | trim }}
    {{- end }}
  {{- else }}
  source:
    {{- /* An explicit appMeta.repoURL may point at an external repo, so it goes through
           cluster.mirrors as a git source. The default (argocdAppLoader.source) is emitted
           as given. */}}
    {{- if .appMeta.repoURL }}
    repoURL: {{ include "argocd-app-loader.mirrorURL" (dict "url" .appMeta.repoURL "kind" "git" "mirror" (eq (include "argocd-app-loader.mirrorFlag" .appMeta.mirror) "true") "cluster" $cluster "Root" .Root) | quote }}
    {{- else }}
    repoURL: {{ $ownRepo | quote }}
    {{- end }}
    targetRevision: {{ $ownRevision | quote }}
    path: {{ $appPath }}
    helm:
      releaseName: {{ $releaseName }}
      {{- /* The wrapper's values, already tpl-rendered against the consumer chart, so
             {{ .Values.cluster.domain }} in them has resolved. Nothing else is added: a wrapper's
             templates see only what its values file passes. */}}
      valuesObject:
{{ toYaml (default dict .wrapperValues) | indent 8 }}
      {{- with $helmPins }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
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
            "maxDuration" "5m")) -}}
    {{- /* concat of two empty lists is nil, which toYaml writes as `syncOptions: null`. */ -}}
    {{- $syncOptions := concat
          (ternary (list "CreateNamespace=true") (list) (default false .appMeta.createNamespace))
          (.appMeta.syncOptions | default list) -}}
    {{- if $syncOptions -}}
      {{- $_ := set $defaultSyncPolicy "syncOptions" $syncOptions -}}
    {{- end -}}
    {{- /* A present syncPolicy replaces the default as written: `{}` means sync by hand. */ -}}
    {{- toYaml (ternary .appMeta.syncPolicy $defaultSyncPolicy (not (kindIs "invalid" .appMeta.syncPolicy))) | nindent 4 }}
  {{- with .appMeta.ignoreDifferences }}
  ignoreDifferences:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .appMeta.info }}
  info:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" .appMeta.revisionHistoryLimit) }}
  revisionHistoryLimit: {{ .appMeta.revisionHistoryLimit }}
  {{- end }}
{{- end -}}


{{- /*
  argocd-app-loader.ownChartSource — the app folder's own chart (Chart.yaml + templates/) as one
  entry of `sources:`, beside an upstream chart or a Kustomize source.
*/ -}}
{{- define "argocd-app-loader.ownChartSource" -}}
- repoURL: {{ .repoURL | quote }}
  targetRevision: {{ .targetRevision | quote }}
  path: {{ .path }}
  helm:
    releaseName: {{ .releaseName }}
    valuesObject:
{{ toYaml .values | indent 6 }}
    {{- with .pins }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with .helm }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end -}}
