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
    apps/<group>/_group.yaml          AppProject metadata
    apps/<group>/<name>/app.yaml      Application metadata
    .Values.global                    Cluster-wide globals (cascaded into apps)
    .Values.apps.<name>               Boolean on/off toggle (default true if missing)

  Customizable via .Values.argocdAppLoader:
    appsRoot       : root path to scan (default "apps")
    requireToggle  : if true, an app is only emitted when .Values.apps.<name>
                     is explicitly true. If false, missing toggles default to
                     true. (default: true)
*/ -}}
{{- define "argocd-app-loader.loader" -}}
{{- $cfg := default dict .Values.argocdAppLoader -}}
{{- $appsRoot := default "apps" $cfg.appsRoot -}}
{{- $requireToggle := default true $cfg.requireToggle -}}

{{- /* Emit one Application per discovered app.yaml */ -}}
{{- $appGlob := printf "%s/*/*/app.yaml" $appsRoot -}}
{{- range $path, $_ := .Files.Glob $appGlob }}
  {{- $parts := splitList "/" $path -}}
  {{- $group := index $parts 1 -}}
  {{- $name  := index $parts 2 -}}
  {{- $toggle := index $.Values.apps $name -}}
  {{- $enabled := ternary $toggle (default false $toggle) (kindIs "bool" $toggle) -}}
  {{- if not $requireToggle -}}
    {{- $enabled = ternary $toggle true (kindIs "bool" $toggle) -}}
  {{- end -}}
  {{- if $enabled }}
    {{- $appMeta := $.Files.Get $path | fromYaml -}}
    {{- $groupPath := printf "%s/%s/_group.yaml" $appsRoot $group -}}
    {{- $groupMeta := $.Files.Get $groupPath | fromYaml | default dict }}
---
{{ include "argocd-app-loader.application" (dict
    "name"      $name
    "group"     $group
    "appMeta"   $appMeta
    "groupMeta" $groupMeta
    "global"    $.Values.global
    "Values"    $.Values
    "Root"      $
) }}
  {{- end }}
{{- end }}

{{- /* Emit one AppProject per discovered _group.yaml */ -}}
{{- $groupGlob := printf "%s/*/_group.yaml" $appsRoot -}}
{{- range $path, $_ := .Files.Glob $groupGlob }}
  {{- $group := index (splitList "/" $path) 1 -}}
  {{- $meta  := $.Files.Get $path | fromYaml | default dict }}
---
{{ include "argocd-app-loader.appproject" (dict
    "name"   $group
    "meta"   $meta
    "global" $.Values.global
    "Values" $.Values
    "Root"   $
) }}
{{- end }}
{{- end -}}
