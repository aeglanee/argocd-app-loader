{{- /*
  argocd-app-loader.root — the root of roots. Call it from the root chart in the instance (fleet)
  repo, the chart the hand-applied bootstrap Application renders:

      # templates/root.yaml
      {{- include "argocd-app-loader.root" . -}}

  It emits:
    - the root Application itself (named after the release, i.e. the bootstrap Application), so
      from its first sync on the root is managed from git;
    - one Application per package the cluster picked, in package waves. A package is a chart
      that renders its apps with argocd-app-loader.loader.

  The root chart sits in the instance repo, at argocdAppLoader.rootPath (required); set it in the
  root chart's own values.yaml. It reads the catalogue's values.yaml (package list and
  defaults) and the instance's files, in that order, and so does every package.

  Catalogue (its values.yaml):
    argocdAppLoader.packages.<name>:
      wave        required: a package waits until every package with a lower wave is healthy
      repoURL     optional: another git repo, resolved through cluster.mirrors; default the
                  catalogue repo
      path        optional: the package chart's folder; default packages/<name> in the catalogue,
                  "." elsewhere
      mirror      optional: false keeps repoURL off cluster.mirrors
  Instance (the cluster's values):
    cluster.packages.<name>: true | false | {version: "<git ref>"}   a map counts as picked
    cluster.instancePackages.<name>: {path, wave, version}            packages in the instance repo
    cluster.instanceValuesFiles: [...]   the instance repo's value files, later ones win
  Repos: cluster.remoteGitRepo/localGitRepo (the catalogue) and cluster.instanceRemoteRepo/
  instanceLocalRepo (this repo), switched by cluster.useLocalGit; cluster.targetRevision (the
  catalogue's), instanceRevision. Git refs must be strings: an unquoted 1.10 would become 1.1.

  The root can't read the packages' files (they're in other repos), so it doesn't run
  argocd-app-loader.check across packages. It does tell every package the names the root and the packages
  take (argocdAppLoader.takenNames): an app with one of them fails its package's render, since
  it would replace that Application.
*/ -}}
{{- define "argocd-app-loader.root" -}}
{{- $c := default dict .Values.cluster -}}
{{- $local := default false $c.useLocalGit -}}
{{- $catalogueKey := ternary "localGitRepo" "remoteGitRepo" $local -}}
{{- /* Required: Helm can't know where the chart sits, and a wrong path strands the root. */ -}}
{{- $rootPath := include "argocd-app-loader.cleanPath" (required "argocd-app-loader: argocdAppLoader.rootPath is required: the root chart's folder in this repo (set it in the chart's own values.yaml)" (default dict .Values.argocdAppLoader).rootPath) -}}
{{- $instanceKey := ternary "instanceLocalRepo" "instanceRemoteRepo" $local -}}
{{- $catalogue := tpl (toString (required (printf "argocd-app-loader: cluster.%s is required (the catalogue's repo)" $catalogueKey) (get $c $catalogueKey))) . -}}
{{- $instance := tpl (toString (required (printf "argocd-app-loader: cluster.%s is required (this repo, the cluster's)" $instanceKey) (get $c $instanceKey))) . -}}
{{- $revision := include "argocd-app-loader.gitRef" (dict "ref" $c.targetRevision "default" "HEAD" "key" "cluster.targetRevision") -}}
{{- $instanceRevision := include "argocd-app-loader.gitRef" (dict "ref" $c.instanceRevision "default" "HEAD" "key" "cluster.instanceRevision") -}}
{{- if not $c.instanceValuesFiles -}}
  {{- fail "argocd-app-loader: cluster.instanceValuesFiles must list at least one file: without one, the root stops reading the cluster's values" -}}
{{- end -}}
{{- $valueFiles := list "$catalogue/values.yaml" -}}
{{- range $f := $c.instanceValuesFiles }}{{ $valueFiles = append $valueFiles (printf "$values/%s" $f) }}{{ end -}}
{{- $valuesRef := dict "repoURL" $instance "targetRevision" $instanceRevision "ref" "values" -}}
{{- $catalogueRef := dict "repoURL" $catalogue "targetRevision" $revision "ref" "catalogue" -}}

{{- /* The root itself, in this repo: it never prunes itself; its children go through the finalizer. */}}
{{- include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" .Release.Name "isRoot" true
    "repoURL" $instance "targetRevision" $instanceRevision "path" $rootPath
    "valueFiles" $valueFiles "refs" (list $catalogueRef $valuesRef)) }}

{{- /*
  Picks. A typo'd or non-bool pick would silently drop a package, and with it, through prune and
  the resources finalizer, every app in it. Picking nothing would do that to the whole cluster.
*/ -}}
{{- $catalogued := default dict (default dict .Values.argocdAppLoader).packages -}}
{{- $instancePackages := default dict $c.instancePackages -}}
{{- $on := dict -}}
{{- range $name, $pick := default dict $c.packages -}}
  {{- if not (hasKey $catalogued $name) -}}
    {{- fail (printf "argocd-app-loader: cluster.packages.%s: no such package; the catalogue has %s" $name (keys $catalogued | sortAlpha | join ", ")) -}}
  {{- end -}}
  {{- if kindIs "map" $pick -}}
    {{- range $k := keys $pick -}}
      {{- if ne $k "version" -}}
        {{- fail (printf "argocd-app-loader: cluster.packages.%s.%s: a pick only takes version" $name $k) -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $on $name (include "argocd-app-loader.gitRef" (dict "ref" $pick.version "default" "" "key" (printf "cluster.packages.%s.version" $name))) -}}
  {{- else if not (kindIs "bool" $pick) -}}
    {{- fail (printf "argocd-app-loader: cluster.packages.%s must be true, false or {version: <git ref>}, got %v (a %s)" $name $pick (kindOf $pick)) -}}
  {{- else if $pick -}}
    {{- $_ := set $on $name "" -}}
  {{- end -}}
{{- end -}}
{{- if not (or $on $instancePackages) -}}
  {{- fail "argocd-app-loader: cluster.packages picks no package: the root would render only itself and prune every app. Pick at least one" -}}
{{- end -}}

{{- /* Names the root and the packages take; an app named the same would replace one. */ -}}
{{- $names := dict .Release.Name "the root" -}}
{{- range $name := keys $catalogued | sortAlpha }}{{ include "argocd-app-loader.claimName" (dict "names" $names "name" $name "by" "a catalogue package") }}{{ end -}}
{{- range $name := keys $instancePackages | sortAlpha }}{{ include "argocd-app-loader.claimName" (dict "names" $names "name" $name "by" "an instance package") }}{{ end -}}
{{- $taken := keys $names | sortAlpha -}}

{{- /* Catalogue packages: in the catalogue repo, or another. */ -}}
{{- range $name := keys $catalogued | sortAlpha }}
  {{- $p := default dict (get $catalogued $name) -}}
  {{- $wave := required (printf "argocd-app-loader: argocdAppLoader.packages.%s.wave is required" $name) $p.wave -}}
  {{- if hasKey $on $name }}
    {{- $version := get $on $name -}}
    {{- $repoURL := $catalogue -}}
    {{- $pkgRevision := default $revision $version -}}
    {{- $path := include "argocd-app-loader.cleanPath" (default (printf "packages/%s" $name) $p.path) -}}
    {{- /* The catalogue's defaults at the package's own revision, if it lives there. */ -}}
    {{- $defaults := dict "repoURL" $catalogue "targetRevision" $pkgRevision "ref" "catalogue" -}}
    {{- if $p.repoURL -}}
      {{- /* Another repo: mirrored like any git source; its own HEAD unless pinned. */ -}}
      {{- $repoURL = include "argocd-app-loader.mirrorURL" (dict "url" $p.repoURL "kind" "git" "mirror" (eq (include "argocd-app-loader.mirrorFlag" $p.mirror) "true") "cluster" $c "Root" $) -}}
      {{- $pkgRevision = default "HEAD" $version -}}
      {{- $path = include "argocd-app-loader.cleanPath" (default "." $p.path) -}}
      {{- $defaults = $catalogueRef -}}
    {{- end }}
---
{{ include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" $name "wave" $wave "taken" $taken
    "repoURL" $repoURL "targetRevision" $pkgRevision "path" $path
    "valueFiles" $valueFiles "refs" (list $defaults $valuesRef)) }}
  {{- end }}
{{- end }}

{{- /* The instance's own packages, in this repo. */ -}}
{{- range $name := keys $instancePackages | sortAlpha }}
  {{- $p := default dict (get $instancePackages $name) -}}
  {{- $wave := required (printf "argocd-app-loader: cluster.instancePackages.%s.wave is required" $name) $p.wave -}}
  {{- $pkgRevision := include "argocd-app-loader.gitRef" (dict "ref" $p.version "default" $instanceRevision "key" (printf "cluster.instancePackages.%s.version" $name)) -}}
  {{- $path := include "argocd-app-loader.cleanPath" (required (printf "argocd-app-loader: cluster.instancePackages.%s.path is required" $name) $p.path) }}
---
{{ include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" $name "wave" $wave "taken" $taken
    "repoURL" $instance "targetRevision" $pkgRevision "path" $path
    "valueFiles" $valueFiles "refs" (list $catalogueRef $valuesRef)) }}
{{- end }}
{{- end -}}

{{- /* argocd-app-loader.claimName — fails when a second Application would get the same name. */ -}}
{{- define "argocd-app-loader.claimName" -}}
{{- with get .names .name -}}
  {{- fail (printf "argocd-app-loader: %s and %s would both be Application/%s" . $.by $.name) -}}
{{- end -}}
{{- $_ := set .names .name .by -}}
{{- end -}}

{{- /* argocd-app-loader.gitRef — a git ref as a string; an unquoted 1.10 would read as 1.1. */ -}}
{{- define "argocd-app-loader.gitRef" -}}
{{- if kindIs "invalid" .ref -}}
  {{- .default -}}
{{- else if kindIs "string" .ref -}}
  {{- .ref -}}
{{- else -}}
  {{- fail (printf "argocd-app-loader: %s must be a string, so quote it (got %v, which YAML reads as a %s)" .key .ref (kindOf .ref)) -}}
{{- end -}}
{{- end -}}

{{- /* argocd-app-loader.cleanPath — a folder path without "./" in front or "/" at the end. */ -}}
{{- define "argocd-app-loader.cleanPath" -}}
{{- $p := trimSuffix "/" (trimPrefix "./" (toString .)) -}}
{{- ternary "." $p (eq $p "") -}}
{{- end -}}

{{- /* argocd-app-loader.rootApplication — the root itself, or one package. */ -}}
{{- define "argocd-app-loader.rootApplication" -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: {{ .cluster.argocdNamespace | default "argocd" }}
  annotations:
    {{- if .isRoot }}
    argocd.argoproj.io/sync-options: Prune=false   # a render that drops it can't delete it
    {{- else }}
    argocd.argoproj.io/sync-wave: {{ .wave | toString | quote }}
    {{- end }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: {{ .repoURL | quote }}
      targetRevision: {{ .targetRevision | quote }}
      path: {{ .path | quote }}
      helm:
        valueFiles:
          {{- toYaml .valueFiles | nindent 10 }}
        {{- if not .isRoot }}
        valuesObject:
          argocdAppLoader:
            source:                     # where this package's files are
              repoURL: {{ .repoURL | quote }}
              targetRevision: {{ .targetRevision | quote }}
              path: {{ .path | quote }}
            takenNames:                 # the root's and the packages': no app may take one
              {{- toYaml .taken | nindent 14 }}
        {{- end }}
    {{- range .refs }}
    - repoURL: {{ .repoURL | quote }}
      targetRevision: {{ .targetRevision | quote }}
      ref: {{ .ref }}
    {{- end }}
  destination:
    server: {{ .cluster.clusterServer | default "https://kubernetes.default.svc" }}
    namespace: {{ .cluster.argocdNamespace | default "argocd" }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # As for apps: a failed sync isn't retried for the same commit otherwise.
    retry:
      limit: 10
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
    syncOptions:
      - ServerSideApply=true
      {{- if .isRoot }}
      - CreateNamespace=true
      {{- end }}
{{- end -}}
