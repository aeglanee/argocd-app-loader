{{- /*
  argocd-app-loader.root — the root of roots. Call it from the catalogue's top chart, the one the
  hand-applied bootstrap Application renders. That chart must sit at its repo's root: the root
  Application points at ".", and package paths are both git paths and paths in this chart.

      # templates/root.yaml
      {{- include "argocd-app-loader.root" . -}}

  It emits:
    - the root Application itself (named after the release, i.e. the bootstrap Application), so
      from its first sync on the root is managed from git;
    - one Application per package the cluster picked, in package waves. A package is a chart
      that renders its apps with argocd-app-loader.loader;
    - nothing else, but it fails the render through argocd-app-loader.check over the packages
      whose files are here, and when two Applications would get the same name.

  Catalogue (this chart's values):
    argocdAppLoader.packages.<name>:
      wave        required: a package waits until every package with a lower wave is healthy
      repoURL     optional: another git repo, resolved through cluster.mirrors; default this repo
      path        optional: the package chart's folder; default packages/<name> here, "." elsewhere
      mirror      optional: false keeps repoURL off cluster.mirrors
      provides    for a package elsewhere: what its apps provide (app names or capabilities), so
                  requires: of the packages here can be checked against it
  Instance (the cluster's values):
    cluster.packages.<name>: true | false | {version: "<git ref>"}   a map counts as picked
    cluster.instancePackages.<name>: {path, wave, version, provides}  packages in the instance repo
    cluster.instanceValuesFiles: [...]   the instance repo's value files, later ones win
  Repos: cluster.remoteGitRepo/localGitRepo (this repo) and cluster.instanceRemoteRepo/
  instanceLocalRepo, switched by cluster.useLocalGit; cluster.targetRevision, instanceRevision.
  Git refs must be strings: an unquoted 1.10 would become 1.1.

  Every package reads the same values: this repo's values.yaml (through the `catalogue` ref, at
  the package's revision if it lives here), then the instance's files. It is told where its own
  files are (argocdAppLoader.source), because Helm can't know where a chart sits in its repo.
*/ -}}
{{- define "argocd-app-loader.root" -}}
{{- $c := default dict .Values.cluster -}}
{{- $local := default false $c.useLocalGit -}}
{{- $catalogueKey := ternary "localGitRepo" "remoteGitRepo" $local -}}
{{- $instanceKey := ternary "instanceLocalRepo" "instanceRemoteRepo" $local -}}
{{- $catalogue := tpl (toString (required (printf "argocd-app-loader: cluster.%s is required (this repo)" $catalogueKey) (get $c $catalogueKey))) . -}}
{{- $instance := tpl (toString (required (printf "argocd-app-loader: cluster.%s is required (the cluster's repo)" $instanceKey) (get $c $instanceKey))) . -}}
{{- $revision := include "argocd-app-loader.gitRef" (dict "ref" $c.targetRevision "default" "HEAD" "key" "cluster.targetRevision") -}}
{{- $instanceRevision := include "argocd-app-loader.gitRef" (dict "ref" $c.instanceRevision "default" "HEAD" "key" "cluster.instanceRevision") -}}
{{- if not $c.instanceValuesFiles -}}
  {{- fail "argocd-app-loader: cluster.instanceValuesFiles must list at least one file: without one, the root stops reading the cluster's values" -}}
{{- end -}}
{{- $valueFiles := list -}}
{{- range $f := $c.instanceValuesFiles }}{{ $valueFiles = append $valueFiles (printf "$values/%s" $f) }}{{ end -}}
{{- $valuesRef := dict "repoURL" $instance "targetRevision" $instanceRevision "ref" "values" -}}

{{- /* The root itself: it never prunes itself, and its children go through the finalizer. */}}
{{- include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" .Release.Name "isRoot" true
    "repoURL" $catalogue "targetRevision" $revision "path" "."
    "valueFiles" $valueFiles "refs" (list $valuesRef)) }}

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

{{- /*
  Packages whose files the check can read: here, and at this chart's own revision. A package
  elsewhere, or pinned to another revision, counts through its declared provides: instead.
*/ -}}
{{- $roots := list -}}
{{- $outside := list -}}
{{- $names := dict .Release.Name "the root" -}}

{{- range $name := keys $catalogued | sortAlpha }}
  {{- $p := default dict (get $catalogued $name) -}}
  {{- $wave := required (printf "argocd-app-loader: argocdAppLoader.packages.%s.wave is required" $name) $p.wave -}}
  {{- $isOn := hasKey $on $name -}}
  {{- $version := get $on $name | default "" -}}
  {{- $here := not $p.repoURL -}}
  {{- $path := include "argocd-app-loader.cleanPath" (default (ternary (printf "packages/%s" $name) "." $here) $p.path) -}}
  {{- include "argocd-app-loader.claimName" (dict "names" $names "name" $name "by" "a catalogue package") -}}
  {{- if and $here (not $version) -}}
    {{- $roots = append $roots (dict "name" $name "path" (printf "%s/apps" $path) "wave" $wave "on" $isOn) -}}
  {{- else if $isOn -}}
    {{- $outside = append $outside (dict "name" $name "provides" (default list $p.provides) "wave" $wave) -}}
  {{- end -}}
  {{- if $isOn }}
    {{- $repoURL := $catalogue -}}
    {{- $pkgRevision := default $revision $version -}}
    {{- $catalogueRevision := $pkgRevision -}}
    {{- if not $here -}}
      {{- /* Another repo: mirrored like any git source; its own HEAD unless pinned. */ -}}
      {{- $repoURL = include "argocd-app-loader.mirrorURL" (dict "url" $p.repoURL "kind" "git" "mirror" (eq (include "argocd-app-loader.mirrorFlag" $p.mirror) "true") "cluster" $c "Root" $) -}}
      {{- $pkgRevision = default "HEAD" $version -}}
      {{- $catalogueRevision = $revision -}}
    {{- end }}
---
{{ include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" $name "wave" $wave
    "repoURL" $repoURL "targetRevision" $pkgRevision "path" $path
    "valueFiles" (prepend $valueFiles "$catalogue/values.yaml")
    "refs" (list (dict "repoURL" $catalogue "targetRevision" $catalogueRevision "ref" "catalogue") $valuesRef)) }}
  {{- end }}
{{- end }}

{{- /* The instance's own packages, in its repo. */ -}}
{{- range $name := keys $instancePackages | sortAlpha }}
  {{- $p := default dict (get $instancePackages $name) -}}
  {{- include "argocd-app-loader.claimName" (dict "names" $names "name" $name "by" "an instance package") -}}
  {{- $wave := required (printf "argocd-app-loader: cluster.instancePackages.%s.wave is required" $name) $p.wave -}}
  {{- $pkgRevision := include "argocd-app-loader.gitRef" (dict "ref" $p.version "default" $instanceRevision "key" (printf "cluster.instancePackages.%s.version" $name)) -}}
  {{- $path := include "argocd-app-loader.cleanPath" (required (printf "argocd-app-loader: cluster.instancePackages.%s.path is required" $name) $p.path) -}}
  {{- $outside = append $outside (dict "name" $name "provides" (default list $p.provides) "wave" $wave) }}
---
{{ include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" $name "wave" $wave
    "repoURL" $instance "targetRevision" $pkgRevision "path" $path
    "valueFiles" (prepend $valueFiles "$catalogue/values.yaml")
    "refs" (list (dict "repoURL" $catalogue "targetRevision" $revision "ref" "catalogue") $valuesRef)) }}
{{- end }}

{{- /* Apps are Applications in the same namespace as the packages and the root. */ -}}
{{- range $r := $roots -}}
  {{- range $file, $_ := $.Files.Glob (printf "%s/*/*/app.yaml" $r.path) -}}
    {{- include "argocd-app-loader.claimName" (dict "names" $names "name" (base (dir $file)) "by" (printf "the app %s" (dir $file))) -}}
  {{- end -}}
{{- end -}}
{{- include "argocd-app-loader.check" (dict "Root" $ "roots" $roots "outside" $outside) -}}
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
