{{- /*
  argocd-app-loader.check — checks across several app roots that each render on their own, such as
  the packages of a root of roots, where no single loader render sees every app. Call it from the
  chart whose .Files hold all the roots; it renders nothing and fails on the first problem:

    - app names are unique across roots (the roots share one cluster.apps toggle map);
    - group names are unique across roots (each group is one AppProject);
    - every `requires:` entry of an app that is on is met by an app that is on, either by its name
      or by listing the entry under `provides:`;
    - a required app comes no later than the app that needs it, comparing (root wave, app wave).

      {{- include "argocd-app-loader.check" (dict "Root" $ "roots" (list
            (dict "name" "core" "path" "packages/core/apps" "wave" 0 "on" true)
            (dict "name" "platform" "path" "packages/platform/apps" "wave" 10 "on" true))) -}}

  "outside" lists packages that are on but whose files aren't here (another repo or revision):
  {name, wave, provides}. Their provides: count as met, by an app at the start of their wave.

  Without "roots" it checks the chart's own argocdAppLoader.appsRoot as one root. A root without
  "on" is on, without "wave" at 0. An app is on when its root is on and its toggle is, by the same
  rule as the loader (argocdAppLoader.requireToggle). The same wave counts as "no later":
  `requires:` says an app needs the other on, not healthy first; a lower wave says that.
*/ -}}
{{- define "argocd-app-loader.check" -}}
{{- $root := .Root -}}
{{- $cfg := default dict $root.Values.argocdAppLoader -}}
{{- /* hasKey, not default: an empty list (every package elsewhere) must stay empty. */ -}}
{{- $roots := ternary .roots (list (dict "name" "" "path" (default "apps" $cfg.appsRoot) "wave" 0 "on" true)) (hasKey . "roots") -}}
{{- $apps := dict -}}
{{- $groups := dict -}}
{{- range $r := $roots -}}
  {{- range $path, $_ := $root.Files.Glob (printf "%s/*/*/app.yaml" $r.path) -}}
    {{- $p := splitList "/" $path -}}
    {{- $group := index $p (sub (len $p) 3) -}}
    {{- $name := index $p (sub (len $p) 2) -}}
    {{- with get $apps $name -}}
      {{- fail (printf "argocd-app-loader: duplicate app name %q in %s and %s — app folder names must be unique across roots, which share cluster.apps" $name .dir (dir $path)) -}}
    {{- end -}}
    {{- with get $groups $group -}}
      {{- if ne . $r.path -}}
        {{- fail (printf "argocd-app-loader: group %q is in both %s and %s — each group is one AppProject, so group folder names must be unique across roots" $group . $r.path) -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $groups $group $r.path -}}
    {{- $meta := $root.Files.Get $path | fromYaml | default dict -}}
    {{- include "argocd-app-loader.requireYaml" (dict "parsed" $meta "file" $path) -}}
    {{- range $key := list "requires" "provides" -}}
      {{- /* index, not get: get returns "" for a missing key. */ -}}
      {{- $v := index $meta $key -}}
      {{- if not (or (kindIs "invalid" $v) (kindIs "slice" $v)) -}}
        {{- fail (printf "argocd-app-loader: %s: %s must be a list, got %s" $path $key (kindOf $v)) -}}
      {{- end -}}
    {{- end -}}
    {{- $rootOn := ternary $r.on true (kindIs "bool" $r.on) -}}
    {{- $on := and $rootOn (eq (include "argocd-app-loader.isOn" (dict "Values" $root.Values "name" $name)) "true") -}}
    {{- $_ := set $apps $name (dict
          "dir" (dir $path)
          "on" $on
          "offRoot" (ternary "" $r.name $rootOn)
          "requires" (default list $meta.requires)
          "provides" (default list $meta.provides)
          "order" (list (int $r.wave) (int (default 0 $meta.wave)))
          "where" (printf "%swave %v" (ternary "" (printf "%s, " $r.name) (empty $r.name)) (default 0 $meta.wave))) -}}
  {{- end -}}
{{- end -}}

{{- /* Who meets each name: the app of that name, and every app listing it under provides:. */ -}}
{{- $providers := dict -}}
{{- range $name, $a := $apps -}}
  {{- range $n := prepend $a.provides $name -}}
    {{- $_ := set $providers (toString $n) (append (get $providers (toString $n) | default list) $name) -}}
  {{- end -}}
{{- end -}}

{{- range $o := default list .outside -}}
  {{- range $n := $o.provides -}}
    {{- $key := printf "%s from package %s" (toString $n) $o.name -}}
    {{- $_ := set $apps $key (dict "dir" "" "on" true "requires" list "provides" list "order" (list (int $o.wave) -1000000) "where" (printf "wave %v" $o.wave) "offRoot" "" "virtual" true) -}}
    {{- $_ := set $providers (toString $n) (append (get $providers (toString $n) | default list) $key) -}}
  {{- end -}}
{{- end -}}

{{- range $name := keys $apps | sortAlpha -}}
  {{- $a := get $apps $name -}}
  {{- if and $a.on (not $a.virtual) -}}
    {{- range $req := $a.requires -}}
      {{- $req = toString $req -}}
      {{- $candidates := get $providers $req | default list -}}
      {{- if not $candidates -}}
        {{- fail (printf "argocd-app-loader: %s requires %s, but no app is named so or provides it" $name $req) -}}
      {{- end -}}
      {{- $met := list -}}
      {{- range $c := $candidates -}}
        {{- if (get $apps $c).on }}{{ $met = append $met $c }}{{ end -}}
      {{- end -}}
      {{- if not $met -}}
        {{- /* Name every app that is on and needs it, so the message says what to switch off first. */ -}}
        {{- $dependents := list -}}
        {{- range $other := keys $apps | sortAlpha -}}
          {{- $o := get $apps $other -}}
          {{- if and $o.on (has $req (default list $o.requires)) }}{{ $dependents = append $dependents $other }}{{ end -}}
        {{- end -}}
        {{- $what := $req -}}
        {{- if not (and (eq (len $candidates) 1) (eq (first $candidates) $req)) -}}
          {{- $what = printf "everything providing %s (%s)" $req (join ", " $candidates) -}}
        {{- end -}}
        {{- $offRoots := list -}}
        {{- range $c := $candidates }}{{ with (get $apps $c).offRoot }}{{ $offRoots = append $offRoots . }}{{ end }}{{ end -}}
        {{- $because := "" -}}
        {{- if $offRoots }}{{ $because = printf " because %s is off" (join " and " (uniq $offRoots)) }}{{ end -}}
        {{- $one := eq (len $dependents) 1 -}}
        {{- fail (printf "argocd-app-loader: %s is off%s, but %s require%s it — switch %s off first, or switch %s on" $what $because (join ", " $dependents) (ternary "s" "" $one) (ternary "it" "them" $one) (join " or " (concat $candidates (uniq $offRoots)))) -}}
      {{- end -}}
      {{- $early := false -}}
      {{- range $m := $met -}}
        {{- $mo := (get $apps $m).order -}}
        {{- if or (lt (index $mo 0) (index $a.order 0)) (and (eq (index $mo 0) (index $a.order 0)) (le (index $mo 1) (index $a.order 1))) -}}
          {{- $early = true -}}
        {{- end -}}
      {{- end -}}
      {{- if not $early -}}
        {{- $m := first $met -}}
        {{- fail (printf "argocd-app-loader: %s (%s) requires %s (%s), which comes later — move one of them" $name $a.where $m (get $apps $m).where) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  argocd-app-loader.isOn — "true" if cluster.apps.<name> switches the app on. A bool is taken as
  written. Anything else counts as on if it isn't empty, or, with argocdAppLoader.requireToggle:
  false, always. NOT `default true`: sprig's default treats an explicit false as empty.
*/ -}}
{{- define "argocd-app-loader.isOn" -}}
{{- $cfg := default dict .Values.argocdAppLoader -}}
{{- $requireToggle := ternary $cfg.requireToggle true (kindIs "bool" $cfg.requireToggle) -}}
{{- $toggle := index (default dict (default dict .Values.cluster).apps) .name -}}
{{- $on := true -}}
{{- if kindIs "bool" $toggle -}}
  {{- $on = $toggle -}}
{{- else if $requireToggle -}}
  {{- $on = not (empty $toggle) -}}
{{- end -}}
{{- ternary "true" "false" $on -}}
{{- end -}}
