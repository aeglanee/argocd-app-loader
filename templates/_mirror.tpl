{{- define "argocd-app-loader.chartKind" -}}
{{- $c := . -}}
{{- range $old := list "oci" "http" "git" "revision" -}}
  {{- if hasKey $c $old -}}
    {{- fail (printf "argocd-app-loader: chart.%s was removed in 0.8 — use chart.repo (full upstream URL, e.g. oci://ghcr.io/org/charts or https://github.com/org/repo) + chart.version" $old) -}}
  {{- end -}}
{{- end -}}
{{- $repo := toString (required "argocd-app-loader: chart.repo is required (the real upstream URL)" $c.repo) -}}
{{- if hasPrefix "oci://" $repo -}}
  {{- if $c.path -}}{{- fail (printf "argocd-app-loader: chart.path is only valid for git charts, not OCI (%s)" $repo) -}}{{- end -}}
  {{- $_ := required (printf "argocd-app-loader: chart.name is required for OCI chart %s" $repo) $c.name -}}oci
{{- else if not (regexMatch "^https?://" $repo) -}}
  {{- fail (printf "argocd-app-loader: chart.repo %q needs a scheme — oci:// for OCI registries, https:// for helm repos and git" $repo) -}}
{{- else if $c.path -}}
  {{- if $c.name -}}{{- fail (printf "argocd-app-loader: chart.name is not used for git charts (%s) — the chart is at chart.path" $repo) -}}{{- end -}}git
{{- else -}}
  {{- $_ := required (printf "argocd-app-loader: chart.name is required for helm repo %s (or set chart.path for a git chart)" $repo) $c.name -}}helm
{{- end -}}
{{- end -}}

{{- define "argocd-app-loader.mirrorURL" -}}
{{- $url := toString .url -}}
{{- $m := default dict .cluster.mirrors -}}
{{- $table := default dict $m.table -}}
{{- $bare := regexReplaceAll "^[a-z]+://" $url "" | trimSuffix "/" -}}
{{- $segs := splitList "/" ($bare | trimSuffix ".git") -}}
{{- $key := "" -}}
{{- range $i := untilStep (len $segs) 0 -1 -}}
  {{- $cand := join "/" (slice $segs 0 $i) -}}
  {{- if and (not $key) (hasKey $table $cand) -}}{{- $key = $cand -}}{{- end -}}
{{- end -}}
{{- $out := ternary $bare $url (eq .kind "oci") -}}
{{- if $key -}}
  {{- $e := default dict (index $table $key) -}}
  {{- $method := toString $e.via -}}
  {{- $fits := dict "harbor" "oci" "shim" "helm" "forgejo" "git" -}}
  {{- if not (hasKey $fits $method) -}}
    {{- fail (printf "argocd-app-loader: cluster.mirrors.table[%q].via=%q — must be one of harbor, shim, forgejo" $key $method) -}}
  {{- end -}}
  {{- if ne (get $fits $method) .kind -}}
    {{- fail (printf "argocd-app-loader: %s is a %s source but matches cluster.mirrors.table[%q] (via %s, for %s sources) — add a more specific key or set mirror: false" $url .kind $key $method (get $fits $method)) -}}
  {{- end -}}
  {{- $cfg := default dict (get (default dict $m.via) $method) -}}
  {{- if and .mirror $cfg.enabled -}}
    {{- if eq $method "harbor" -}}
      {{- $host := required "argocd-app-loader: cluster.mirrors.via.harbor.host is required when harbor is enabled" $cfg.host -}}
      {{- $proj := required (printf "argocd-app-loader: cluster.mirrors.table[%q].project is required (via harbor)" $key) $e.project -}}
      {{- $out = join "/" (concat (list $host $proj) (slice $segs (len (splitList "/" $key)))) -}}
    {{- else if eq $method "shim" -}}
      {{- $host := $cfg.host | default (get (default dict (get (default dict $m.via) "harbor")) "host") -}}
      {{- $host = required "argocd-app-loader: cluster.mirrors.via.shim.host (or via.harbor.host) is required when shim is enabled" $host -}}
      {{- $proj := required "argocd-app-loader: cluster.mirrors.via.shim.project is required when shim is enabled" $cfg.project -}}
      {{- $out = printf "%s/%s/%s" $host $proj $bare -}}
    {{- else -}}
      {{- $base := required "argocd-app-loader: cluster.mirrors.via.forgejo.base is required when forgejo is enabled" $cfg.base -}}
      {{- $repo := required (printf "argocd-app-loader: cluster.mirrors.table[%q].repo is required (via forgejo)" $key) $e.repo -}}
      {{- $out = printf "%s/%s" (trimSuffix "/" (toString $base)) $repo -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- tpl $out .Root -}}
{{- end -}}

{{- define "argocd-app-loader.mirrorFlag" -}}
{{- ternary . true (kindIs "bool" .) -}}
{{- end -}}
