{{- define "argocd-app-loader.root" -}}
{{- $c := default dict .Values.cluster -}}
{{- $local := default false $c.useLocalGit -}}
{{- $catalogueKey := ternary "localGitRepo" "remoteGitRepo" $local -}}
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

{{- include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" .Release.Name "isRoot" true
    "repoURL" $instance "targetRevision" $instanceRevision "path" $rootPath
    "valueFiles" $valueFiles "refs" (list $catalogueRef $valuesRef)) }}

{{- if (default dict .Values.argocdAppLoader).packages -}}
  {{- fail "argocd-app-loader: argocdAppLoader.packages moved to cluster.packages: each package's wave, source and apps sit beside enabled (README)" -}}
{{- end -}}
{{- $catalogued := default dict $c.packages -}}
{{- $instancePackages := default dict $c.instancePackages -}}
{{- $on := dict -}}
{{- include "argocd-app-loader.noFlatToggles" $c -}}
{{- $known := list -}}
{{- range $name, $p := $catalogued }}{{ if and (kindIs "map" $p) (hasKey $p "wave") }}{{ $known = append $known $name }}{{ end }}{{ end -}}
{{- range $name, $p := $catalogued -}}
  {{- if not (kindIs "map" $p) -}}
    {{- fail (printf "argocd-app-loader: cluster.packages.%s must be a map, {enabled: true} or {enabled: false}, got %v (a %s)" $name $p (kindOf $p)) -}}
  {{- end -}}
  {{- if not (or (hasKey $p "wave") (hasKey $p "apps")) -}}
    {{- fail (printf "argocd-app-loader: cluster.packages.%s isn't a package the catalogue defines (no wave, no apps); a typo? The packages: %s" $name (join ", " (sortAlpha $known))) -}}
  {{- end -}}
  {{- range $k := keys $p -}}
    {{- if not (has $k (list "enabled" "version" "apps" "overrides" "wave" "repoURL" "path" "mirror")) -}}
      {{- fail (printf "argocd-app-loader: cluster.packages.%s.%s: a package takes enabled, version, apps, overrides, wave, repoURL, path, mirror" $name $k) -}}
    {{- end -}}
  {{- end -}}
  {{- if not (kindIs "bool" $p.enabled) -}}
    {{- fail (printf "argocd-app-loader: cluster.packages.%s.enabled must be true or false, got %v" $name $p.enabled) -}}
  {{- end -}}
  {{- if not (kindIs "map" $p.apps) -}}
    {{- fail (printf "argocd-app-loader: cluster.packages.%s.apps is required: every app of the package, true or false" $name) -}}
  {{- end -}}
  {{- if $p.enabled -}}
    {{- $_ := set $on $name (include "argocd-app-loader.gitRef" (dict "ref" $p.version "default" "" "key" (printf "cluster.packages.%s.version" $name))) -}}
  {{- end -}}
{{- end -}}
{{- range $name, $p := $instancePackages -}}
  {{- range $k := keys (default dict $p) -}}
    {{- if not (has $k (list "path" "wave" "version" "apps" "overrides")) -}}
      {{- fail (printf "argocd-app-loader: cluster.instancePackages.%s.%s: an instance package takes path, wave, version, apps, overrides" $name $k) -}}
    {{- end -}}
  {{- end -}}
  {{- if not (kindIs "map" (default dict $p).apps) -}}
    {{- fail (printf "argocd-app-loader: cluster.instancePackages.%s.apps is required: every app of the package, true or false" $name) -}}
  {{- end -}}
{{- end -}}
{{- if not (or $on $instancePackages) -}}
  {{- fail "argocd-app-loader: cluster.packages picks no package: the root would render only itself and prune every app. Pick at least one" -}}
{{- end -}}

{{- include "argocd-app-loader.dependencies" (dict "Root" $ "all" true) -}}

{{- $names := dict -}}
{{- range $name := keys $catalogued | sortAlpha }}{{ include "argocd-app-loader.claimName" (dict "names" $names "name" $name "by" "a catalogue package") }}{{ end -}}
{{- range $name := keys $instancePackages | sortAlpha }}{{ include "argocd-app-loader.claimName" (dict "names" $names "name" $name "by" "an instance package") }}{{ end -}}
{{- if hasPrefix "pkg-" .Release.Name -}}
  {{- fail (printf "argocd-app-loader: the root is named %s, but pkg-* names are the packages'" .Release.Name) -}}
{{- end -}}

{{- range $name := keys $catalogued | sortAlpha }}
  {{- $p := default dict (get $catalogued $name) -}}
  {{- $wave := required (printf "argocd-app-loader: cluster.packages.%s.wave is required" $name) $p.wave -}}
  {{- if hasKey $on $name }}
    {{- $version := get $on $name -}}
    {{- $repoURL := $catalogue -}}
    {{- $pkgRevision := default $revision $version -}}
    {{- $path := include "argocd-app-loader.cleanPath" (default (printf "packages/%s" $name) $p.path) -}}
    {{- $defaults := dict "repoURL" $catalogue "targetRevision" $pkgRevision "ref" "catalogue" -}}
    {{- if $p.repoURL -}}
      {{- $repoURL = include "argocd-app-loader.mirrorURL" (dict "url" $p.repoURL "kind" "git" "mirror" (eq (include "argocd-app-loader.mirrorFlag" $p.mirror) "true") "cluster" $c "Root" $) -}}
      {{- $pkgRevision = default "HEAD" $version -}}
      {{- $path = include "argocd-app-loader.cleanPath" (default "." $p.path) -}}
      {{- $defaults = $catalogueRef -}}
    {{- end }}
---
{{ include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" $name "wave" $wave "rootName" $.Release.Name
    "repoURL" $repoURL "targetRevision" $pkgRevision "path" $path
    "valueFiles" $valueFiles "refs" (list $defaults $valuesRef)) }}
  {{- end }}
{{- end }}

{{- range $name := keys $instancePackages | sortAlpha }}
  {{- $p := default dict (get $instancePackages $name) -}}
  {{- $wave := required (printf "argocd-app-loader: cluster.instancePackages.%s.wave is required" $name) $p.wave -}}
  {{- $pkgRevision := include "argocd-app-loader.gitRef" (dict "ref" $p.version "default" $instanceRevision "key" (printf "cluster.instancePackages.%s.version" $name)) -}}
  {{- $path := include "argocd-app-loader.cleanPath" (required (printf "argocd-app-loader: cluster.instancePackages.%s.path is required" $name) $p.path) }}
---
{{ include "argocd-app-loader.rootApplication" (dict
    "cluster" $c "name" $name "wave" $wave "rootName" $.Release.Name
    "repoURL" $instance "targetRevision" $pkgRevision "path" $path
    "valueFiles" $valueFiles "refs" (list $catalogueRef $valuesRef)) }}
{{- end }}
{{- end -}}

{{- define "argocd-app-loader.claimName" -}}
{{- with get .names .name -}}
  {{- fail (printf "argocd-app-loader: %s and %s would both be Application/pkg-%s" . $.by $.name) -}}
{{- end -}}
{{- $_ := set .names .name .by -}}
{{- end -}}

{{- define "argocd-app-loader.gitRef" -}}
{{- if kindIs "invalid" .ref -}}
  {{- .default -}}
{{- else if kindIs "string" .ref -}}
  {{- .ref -}}
{{- else -}}
  {{- fail (printf "argocd-app-loader: %s must be a string, so quote it (got %v, which YAML reads as a %s)" .key .ref (kindOf .ref)) -}}
{{- end -}}
{{- end -}}

{{- define "argocd-app-loader.cleanPath" -}}
{{- $p := trimSuffix "/" (trimPrefix "./" (toString .)) -}}
{{- ternary "." $p (eq $p "") -}}
{{- end -}}

{{- define "argocd-app-loader.rootApplication" -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ ternary .name (printf "pkg-%s" .name) (default false .isRoot) }}
  namespace: {{ .cluster.argocdNamespace | default "argocd" }}
  annotations:
    {{- if .isRoot }}
    argocd.argoproj.io/sync-options: Prune=false
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
            source:
              repoURL: {{ .repoURL | quote }}
              targetRevision: {{ .targetRevision | quote }}
              path: {{ .path | quote }}
            package: {{ .name | quote }}
            rootName: {{ .rootName | quote }}
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
