{{- /*
  argocd-app-loader.loader — discover apps + groups on the consumer chart's filesystem
  and emit one Application per enabled app + one AppProject per group.

  Call this from a single template file in the consumer chart, e.g.:

      # consumer/templates/render.yaml
      {{- include "argocd-app-loader.loader" . -}}

  $.Files always refers to the root consumer chart, so this define reads
  apps/<group>/<app>/app.yaml relative to the consumer's directory regardless
  of where this library is installed.

  Conventions consumed:
    apps/<group>/_group.yaml             AppProject metadata
    apps/<group>/<name>/app.yaml         Application metadata
    .Values.cluster.apps.<name>           Boolean on/off toggle for each app
    .Values.cluster.overrides.<name>      Merged over the app's rendered values
    .Values.argocdAppLoader.source        Where this chart's files live (repoURL, targetRevision, path)
    .Values.argocdAppLoader.takenNames    Application names apps can't use (set by the root of roots)

  Customizable via .Values.argocdAppLoader:
    appsRoot       : root path to scan (default "apps")
    requireToggle  : if true, an app is only emitted when its toggle is
                     explicitly true. If false, missing toggles default to
                     true. (default: true)
*/ -}}
{{- define "argocd-app-loader.loader" -}}
{{- $cfg := default dict .Values.argocdAppLoader -}}
{{- $appsRoot := default "apps" $cfg.appsRoot -}}
{{- /* Fail loudly on the pre-0.8 airgap keys rather than silently ignoring them. */ -}}
{{- range $old := list "useLocalRegistry" "ociRepos" "shimProxy" "localRegistryHost" "gitMirrors" "localGitBase" -}}
  {{- if hasKey (default dict $.Values.cluster) $old -}}
    {{- fail (printf "argocd-app-loader: cluster.%s was removed in 0.8 — chart/git mirroring is now cluster.mirrors {via, table} (see README)" $old) -}}
  {{- end -}}
{{- end -}}
{{- if hasKey (default dict $.Values.cluster) "repoBasePath" -}}
  {{- fail "argocd-app-loader: cluster.repoBasePath was removed in 0.9 — set argocdAppLoader.source.path (see README)" -}}
{{- end -}}

{{- /* Emit one Application per discovered app.yaml */ -}}
{{- $appGlob := printf "%s/*/*/app.yaml" $appsRoot -}}
{{- /*
  Guard: app folder names must be unique ACROSS groups. The toggle map and the
  default release/path are keyed by the bare app name, so two apps sharing a
  name in different groups would silently collide on one toggle. Fail loudly.
*/ -}}
{{- $seenNames := dict -}}
{{- range $path, $_ := .Files.Glob $appGlob -}}
  {{- /* Read from the end: appsRoot may be several folders deep. */ -}}
  {{- $p := splitList "/" $path -}}
  {{- $g := index $p (sub (len $p) 3) -}}
  {{- $n := index $p (sub (len $p) 2) -}}
  {{- if hasKey $seenNames $n -}}
    {{- fail (printf "argocd-app-loader: duplicate app name %q in groups %q and %q — app folder names must be unique across groups" $n (index $seenNames $n) $g) -}}
  {{- end -}}
  {{- $_ := set $seenNames $n $g -}}
  {{- /* Names the root of roots says it and the packages take: an app with one would replace it. */ -}}
  {{- if has $n (default list $cfg.takenNames) -}}
    {{- fail (printf "argocd-app-loader: app %s/%s has the name of the root or a package; both would be Application/%s, so rename the app" $g $n $n) -}}
  {{- end -}}
{{- end -}}
{{- /* The lowest wave of an app that is on (0 at most): AppProjects go one below it. */ -}}
{{- $firstWave := 0 -}}
{{- range $path, $_ := .Files.Glob $appGlob }}
  {{- $parts := splitList "/" $path -}}
  {{- $group := index $parts (sub (len $parts) 3) -}}
  {{- $name  := index $parts (sub (len $parts) 2) -}}
  {{- if eq (include "argocd-app-loader.isOn" (dict "Values" $.Values "name" $name)) "true" }}
    {{- $appMeta := $.Files.Get $path | fromYaml -}}
    {{- include "argocd-app-loader.requireYaml" (dict "parsed" $appMeta "file" $path) -}}
    {{- $firstWave = min $firstWave (int (default 0 $appMeta.wave)) -}}
    {{- /* v2: does the app dir carry its own local chart (Chart.yaml + templates/)? → source B */ -}}
    {{- $hasLocalChart := ne ($.Files.Get (printf "%s/%s/%s/Chart.yaml" $appsRoot $group $name)) "" -}}
    {{- $appDir := printf "%s/%s/%s" $appsRoot $group $name -}}
    {{- /* Kustomize form: kustomize/ is rendered by Kustomize, beside the local chart. Kustomize
           accepts three file names. */ -}}
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
    {{- /*
      Read the wrapper's templated values, tpl-render against the consumer
      chart context, and parse to YAML. The rendered values go into the
      emitted Application via helm.valuesObject — this is the only way to get
      tpl semantics on values feeding an upstream subchart, since Helm itself
      doesn't tpl values.yaml.

      Preferred filename: values.yaml.gotmpl. Helm does NOT auto-load it
      (only files literally named values.yaml are auto-loaded), so wrappers
      can use Go-template directives — including conditionals at YAML
      top level — without breaking Helm's raw parse of the chart. If
      values.yaml.gotmpl is absent we fall back to values.yaml for
      back-compat with charts that only use string-internal templating.
    */ -}}
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
    {{- /* The instance's escape hatch, merged last: maps merge, lists and scalars are replaced. */ -}}
    {{- $override := index (default dict $.Values.cluster.overrides) $name -}}
    {{- if not (kindIs "invalid" $override) -}}
      {{- if not (kindIs "map" $override) -}}
        {{- fail (printf "argocd-app-loader: cluster.overrides.%s must be a mapping of values, got %s" $name (kindOf $override)) -}}
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

{{- /* Emit one AppProject per discovered _group.yaml */ -}}
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
{{- end -}}

{{- /*
  fromYaml never fails: when a file doesn't parse into a mapping it returns {"Error": "error ..."},
  which would otherwise be used as the file's content (an app whose values don't parse deploys its
  chart's defaults). Fail instead.
*/ -}}
{{- define "argocd-app-loader.requireYaml" -}}
{{- $err := toString (get .parsed "Error") -}}
{{- if and (eq (len .parsed) 1) (hasPrefix "error " $err) -}}
  {{- fail (printf "argocd-app-loader: %s is not a valid YAML mapping%s: %s" .file (ternary " after templating" "" (default false .templated)) $err) -}}
{{- end -}}
{{- end -}}
