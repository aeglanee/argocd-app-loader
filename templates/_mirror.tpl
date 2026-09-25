{{- /*
  argocd-app-loader.chartKind — infer an app.yaml `chart:` block's source type from its fields.

    repo: oci://…                → "oci"   (OCI Helm registry)
    repo: https://… + path       → "git"   (Helm chart inside a git repo; version = git ref)
    repo: https://… (no path)    → "helm"  (classic HTTP Helm repo with an index.yaml)

  Anything else fails the render loudly — there is no silent fallback. The pre-0.8 keys
  (chart.oci / chart.http / chart.git / chart.revision) are rejected with a migration hint.

  Input: the chart dict.
*/ -}}
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

{{- /*
  argocd-app-loader.mirrorURL — resolve one upstream URL through cluster.mirrors.

  cluster.mirrors:
    via:     # one switch per mirror METHOD
      harbor:  { enabled, host }            oci  → <host>/<project>/<rest-after-key>
      shim:    { enabled, host, project }   helm → <host>/<project>/<repo-host+path>   (served as OCI)
      forgejo: { enabled, base }            git  → <base>/<repo>
    table:   # scheme-less upstream prefix → { via, project | repo }
      ghcr.io:                          { via: harbor, project: ghcr-proxy }
      charts.longhorn.io:               { via: shim }
      github.com/deuxfleurs-org/garage: { via: forgejo, repo: garage }

  Rule — the URL goes private ONLY when all three hold, otherwise it is returned public:
    1. the app did not opt out (mirror: false),
    2. a table key matches (longest prefix, whole path segments only),
    3. that entry's method is enabled.
  A missing entry is never an error (cold-start safe: public is the default). A matched entry
  whose method does not fit the source type IS an error, even while the method is disabled,
  so a bad table fails at bootstrap rather than on the day you flip the switch.

  Public form: OCI loses its oci:// (ArgoCD OCI Helm sources take a scheme-less repoURL + the
  chart field); helm and git URLs are returned exactly as written.

  Input dict: url, kind (oci|helm|git), mirror (bool), cluster, Root (for tpl of the result).
*/ -}}
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

{{- /* argocd-app-loader.mirrorFlag — a `mirror:` field as a bool; absent means true. */ -}}
{{- define "argocd-app-loader.mirrorFlag" -}}
{{- ternary . true (kindIs "bool" .) -}}
{{- end -}}
