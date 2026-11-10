{{- define "argocd-app-loader.loader" -}}
{{- $cfg := default dict .Values.argocdAppLoader -}}
{{- $appsRoot := default "apps" $cfg.appsRoot -}}
{{- range $old := list "useLocalRegistry" "ociRepos" "shimProxy" "localRegistryHost" "gitMirrors" "localGitBase" -}}
  {{- if hasKey (default dict $.Values.cluster) $old -}}
    {{- fail (printf "argocd-app-loader: cluster.%s was removed in 0.8 — chart/git mirroring is now cluster.mirrors {via, table} (see README)" $old) -}}
  {{- end -}}
{{- end -}}
{{- if hasKey (default dict $.Values.cluster) "repoBasePath" -}}
  {{- fail "argocd-app-loader: cluster.repoBasePath was removed in 0.9 — set argocdAppLoader.source.path (see README)" -}}
{{- end -}}
{{- if $cfg.package }}{{ include "argocd-app-loader.noFlatToggles" $.Values.cluster }}{{ end -}}
{{- $overrides := include "argocd-app-loader.scoped" (dict "Values" $.Values "package" $cfg.package "key" "overrides") | fromYaml -}}
{{- $overridesKey := include "argocd-app-loader.scopedKey" (dict "Values" $.Values "package" $cfg.package "key" "overrides") -}}

{{- $appGlob := printf "%s/*/*/app.yaml" $appsRoot -}}
{{- $seenNames := dict -}}
{{- range $path, $_ := .Files.Glob $appGlob -}}
  {{- $p := splitList "/" $path -}}
  {{- $g := index $p (sub (len $p) 3) -}}
  {{- $n := index $p (sub (len $p) 2) -}}
  {{- if hasKey $seenNames $n -}}
    {{- fail (printf "argocd-app-loader: duplicate app name %q in groups %q and %q — app folder names must be unique across groups" $n (index $seenNames $n) $g) -}}
  {{- end -}}
  {{- $_ := set $seenNames $n $g -}}
  {{- if or (hasPrefix "pkg-" $n) (and $cfg.rootName (eq $n (toString $cfg.rootName))) -}}
    {{- fail (printf "argocd-app-loader: app %s/%s would clash with the root of roots or a package (pkg-*); rename the app" $g $n) -}}
  {{- end -}}
{{- end -}}
{{- $firstWave := 0 -}}
{{- range $path, $_ := .Files.Glob $appGlob }}
  {{- $parts := splitList "/" $path -}}
  {{- $group := index $parts (sub (len $parts) 3) -}}
  {{- $name  := index $parts (sub (len $parts) 2) -}}
  {{- if eq (include "argocd-app-loader.isOn" (dict "Values" $.Values "name" $name "package" $cfg.package)) "true" }}
    {{- $appMeta := $.Files.Get $path | fromYaml -}}
    {{- include "argocd-app-loader.requireYaml" (dict "parsed" $appMeta "file" $path) -}}
    {{- $firstWave = min $firstWave (int (default 0 $appMeta.wave)) -}}
    {{- range $old := list "requires" "provides" -}}
      {{- if hasKey $appMeta $old -}}
        {{- fail (printf "argocd-app-loader: %s: %s: moved to argocdAppLoader.dependencies in 0.9 (see README), so it would do nothing here" $path $old) -}}
      {{- end -}}
    {{- end -}}
    {{- $hasLocalChart := ne ($.Files.Get (printf "%s/%s/%s/Chart.yaml" $appsRoot $group $name)) "" -}}
    {{- $appDir := printf "%s/%s/%s" $appsRoot $group $name -}}
    {{- $hasKustomize := false -}}
    {{- range $f := list "kustomization.yaml" "kustomization.yml" "Kustomization" -}}
      {{- if ne ($.Files.Get (printf "%s/kustomize/%s" $appDir $f)) "" }}{{ $hasKustomize = true }}{{ end -}}
    {{- end -}}
    {{- range $key := list "sources" "repoURL" -}}
      {{- if and (index $appMeta $key) $hasLocalChart -}}
        {{- fail (printf "argocd-app-loader: %s has %s: in app.yaml and a Chart.yaml; %s: replaces the local chart, so move the chart into it or remove the Chart.yaml" $appDir $key $key) -}}
      {{- end -}}
    {{- end -}}
    {{- if and $hasKustomize (or $appMeta.chart $appMeta.sources) -}}
      {{- fail (printf "argocd-app-loader: %s has kustomize/ and %s in app.yaml; the Kustomize form renders the upstream chart itself, so use one of them" $appDir (ternary "chart:" "sources:" (not (empty $appMeta.chart)))) -}}
    {{- end -}}
    {{- $groupPath := printf "%s/%s/_group.yaml" $appsRoot $group -}}
    {{- $groupMeta := $.Files.Get $groupPath | fromYaml | default dict -}}
    {{- include "argocd-app-loader.requireYaml" (dict "parsed" $groupMeta "file" $groupPath) -}}
    {{- $rawValues := "" -}}
    {{- $valuesPath := printf "%s/%s/%s/values.yaml.gotmpl" $appsRoot $group $name -}}
    {{- $plainPath := printf "%s/%s/%s/values.yaml" $appsRoot $group $name -}}
    {{- if $.Files.Get $valuesPath -}}
      {{- $rawValues = $.Files.Get $valuesPath -}}
    {{- else if $.Files.Get $plainPath -}}
      {{- $rawValues = $.Files.Get $plainPath -}}
      {{- $valuesPath = $plainPath -}}
    {{- end -}}
    {{- $wrapperValues := dict -}}
    {{- if $rawValues -}}
      {{- $rendered := tpl $rawValues $ -}}
      {{- if $rendered -}}
        {{- $wrapperValues = fromYaml $rendered | default dict -}}
        {{- include "argocd-app-loader.requireYaml" (dict "parsed" $wrapperValues "file" $valuesPath "templated" true) -}}
      {{- end -}}
    {{- end -}}
    {{- $override := index $overrides $name -}}
    {{- if not (kindIs "invalid" $override) -}}
      {{- if not (kindIs "map" $override) -}}
        {{- fail (printf "argocd-app-loader: %s.%s must be a mapping of values, got %s" $overridesKey $name (kindOf $override)) -}}
      {{- end -}}
      {{- $wrapperValues = mustMergeOverwrite (deepCopy $wrapperValues) (deepCopy $override) -}}
    {{- end }}
---
{{ include "argocd-app-loader.application" (dict
    "name"          $name
    "group"         $group
    "appMeta"       $appMeta
    "hasLocalChart" $hasLocalChart
    "hasKustomize"  $hasKustomize
    "appDir"        $appDir
    "groupMeta"     $groupMeta
    "wrapperValues" $wrapperValues
    "cluster"        $.Values.cluster
    "Values"        $.Values
    "Root"          $
) }}
  {{- end }}
{{- end }}

{{- $groupGlob := printf "%s/*/_group.yaml" $appsRoot -}}
{{- range $path, $_ := .Files.Glob $groupGlob }}
  {{- $p := splitList "/" $path -}}
  {{- $group := index $p (sub (len $p) 2) -}}
  {{- $meta  := $.Files.Get $path | fromYaml | default dict -}}
  {{- include "argocd-app-loader.requireYaml" (dict "parsed" $meta "file" $path) }}
---
{{ include "argocd-app-loader.appproject" (dict
    "name"   $group
    "meta"   $meta
    "wave"   (sub $firstWave 1)
    "cluster" $.Values.cluster
    "Values" $.Values
    "Root"   $
) }}
{{- end }}
{{- include "argocd-app-loader.dependencies" (dict "Root" $) }}
{{- end -}}

{{- define "argocd-app-loader.requireYaml" -}}
{{- $err := toString (get .parsed "Error") -}}
{{- if and (eq (len .parsed) 1) (hasPrefix "error " $err) -}}
  {{- fail (printf "argocd-app-loader: %s is not a valid YAML mapping%s: %s" .file (ternary " after templating" "" (default false .templated)) $err) -}}
{{- end -}}
{{- end -}}
