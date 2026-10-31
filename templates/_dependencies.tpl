{{- /*
  argocd-app-loader.dependencies — the dependency list, checked in every package's own render.
  Each package renders and syncs on its own, so a check only stops a deletion if it runs inside
  the package that would delete. The list sits in values every package reads (the catalogue's
  values.yaml), so each one sees every dependency, also those of apps in other packages:

      argocdAppLoader:
        dependencies:              # opt-in: an app that isn't listed is never checked
          harbor:
            package: platform      # the package its app is in (not needed in a single chart)
            requires: [cnpg, storage.replicated]   # app names, or what some app provides:
          longhorn:
            package: core
            provides: [storage.replicated]

  A listed app is on when its toggle is and its package is picked. Each package checks only its
  own listed apps, and fails when:
    - one that is on requires something no app that is on is named or provides;
    - one that is off is required (by name, or for something only it provides) by an app that is
      on, anywhere; so nothing is pruned until the dependents are off too;
    - a requirement comes later: from a later package wave, or inside one package a later app
      wave (the same wave passes);
    - a required name isn't in the list at all (a typo, or an entry removed while something on
      still requires it; this fails every render, also the one that would prune), a package name
      is unknown, a listed app isn't in the package it names, or an app of this package is listed
      under another one.

  Limits: a package pinned to a version checks the list at that version; removing a provider and
  its dependents in one commit passes, and the packages then prune in parallel, so switch the
  dependents off first. Duplicate names of unlisted apps or of groups across packages aren't
  seen.

  argocdAppLoader.package names the package being rendered; the root of roots sets it. Without it
  (a single chart), every listed app belongs here.

  The root of roots calls it with "all" true: it checks every listed app, since switching a whole
  package off is its decision (it would prune the package Application). It can't read the
  packages' files, so it skips what needs them: whether a listed app exists, and app waves.
*/ -}}
{{- define "argocd-app-loader.dependencies" -}}
{{- $root := .Root -}}
{{- $V := $root.Values -}}
{{- $cfg := default dict $V.argocdAppLoader -}}
{{- /* A null entry drops out: a cluster's file can remove one the catalogue lists. */ -}}
{{- $deps := dict -}}
{{- $nulled := list -}}
{{- range $n, $e := default dict $cfg.dependencies -}}
  {{- if kindIs "invalid" $e -}}
    {{- $nulled = append $nulled $n -}}
  {{- else if not (kindIs "map" $e) -}}
    {{- fail (printf "argocd-app-loader: dependencies.%s must be a mapping (package, requires, provides), got %s" $n (kindOf $e)) -}}
  {{- else -}}
    {{- $_ := set $deps $n $e -}}
  {{- end -}}
{{- end -}}
{{- if $deps -}}
{{- $all := default false .all -}}
{{- $self := ternary "" (toString (default "" $cfg.package)) $all -}}
{{- $c := default dict $V.cluster -}}
{{- $picks := default dict $c.packages -}}

{{- /* Packages: picked or not, and their wave. The one being rendered is picked. */ -}}
{{- $pkgs := dict -}}
{{- range $n, $p := default dict $cfg.packages -}}
  {{- $pick := get $picks $n -}}
  {{- $_ := set $pkgs $n (dict "on" (or (kindIs "map" $pick) (eq (toString $pick) "true") (eq $n $self)) "wave" (int (default 0 (default dict $p).wave))) -}}
{{- end -}}
{{- range $n, $p := default dict $c.instancePackages -}}
  {{- $_ := set $pkgs $n (dict "on" true "wave" (int (default 0 (default dict $p).wave))) -}}
{{- end -}}

{{- /* This chart's apps and their waves. */ -}}
{{- $mine := dict -}}
{{- range $path, $_ := ternary (dict) ($root.Files.Glob (printf "%s/*/*/app.yaml" (default "apps" $cfg.appsRoot))) $all -}}
  {{- $p := splitList "/" $path -}}
  {{- $meta := $root.Files.Get $path | fromYaml | default dict -}}
  {{- $_ := set $mine (index $p (sub (len $p) 2)) (int (default 0 $meta.wave)) -}}
{{- end -}}

{{- /* Every listed app: its package, whether it is on, its place in the order. */ -}}
{{- $apps := dict -}}
{{- range $name := keys $deps | sortAlpha -}}
  {{- $e := default dict (get $deps $name) -}}
  {{- $pkg := toString (default "" $e.package) -}}
  {{- if and (or $self (and $all $pkgs)) (not $pkg) -}}
    {{- fail (printf "argocd-app-loader: dependencies.%s needs package: (the package its app is in)" $name) -}}
  {{- end -}}
  {{- if and $pkg (not (hasKey $pkgs $pkg)) -}}
    {{- fail (printf "argocd-app-loader: dependencies.%s.package: no package %q" $name $pkg) -}}
  {{- end -}}
  {{- range $key := list "requires" "provides" -}}
    {{- $v := index $e $key -}}
    {{- if not (or (kindIs "invalid" $v) (kindIs "slice" $v)) -}}
      {{- fail (printf "argocd-app-loader: dependencies.%s.%s must be a list, got %s" $name $key (kindOf $v)) -}}
    {{- end -}}
  {{- end -}}
  {{- $isMine := or (not $self) (eq $pkg $self) -}}
  {{- if and $isMine (not $all) (not (hasKey $mine $name)) -}}
    {{- fail (printf "argocd-app-loader: dependencies.%s is listed under package %s, which has no app %s" $name (default "here" $pkg) $name) -}}
  {{- end -}}
  {{- $pkgOn := true -}}
  {{- $pw := 0 -}}
  {{- if $pkg }}{{ $pkgOn = (get $pkgs $pkg).on }}{{ $pw = (get $pkgs $pkg).wave }}{{ end -}}
  {{- $on := and $pkgOn (eq (include "argocd-app-loader.isOn" (dict "Values" $V "name" $name)) "true") -}}
  {{- $_ := set $apps $name (dict
        "package" $pkg "mine" $isMine "on" $on "pkgOn" $pkgOn
        "requires" (default list $e.requires) "provides" (default list $e.provides)
        "pw" $pw "aw" (ternary 0 (ternary (get $mine $name) 0 $isMine) $all)
        "label" (ternary $name (printf "%s (%s)" $name $pkg) (and (or $isMine (not $pkg)) (not $all)))
        "offLabel" (ternary (printf "%s (package %s isn't picked)" $name $pkg) "" (not $pkgOn))) -}}
{{- end -}}
{{- if $self -}}
  {{- range $name := keys $mine | sortAlpha -}}
    {{- with get $apps $name -}}
      {{- if not .mine -}}
        {{- fail (printf "argocd-app-loader: app %s is in package %s, but dependencies list it under package %s" $name $self .package) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- /* Who meets each name: the app of that name, and every app listing it under provides. */ -}}
{{- $providers := dict -}}
{{- range $name, $a := $apps -}}
  {{- range $n := prepend $a.provides $name -}}
    {{- $_ := set $providers (toString $n) (append (get $providers (toString $n) | default list) $name) -}}
  {{- end -}}
{{- end -}}

{{- /* Every app that is on, anywhere: what it requires must be listed. Run in every render, so a
       provider whose entry was removed can't slip out in the render that prunes it. */ -}}
{{- range $name := keys $apps | sortAlpha -}}
  {{- $a := get $apps $name -}}
  {{- if $a.on -}}
    {{- range $req := $a.requires -}}
      {{- if not (get $providers (toString $req)) -}}
        {{- if has (toString $req) $nulled -}}
          {{- fail (printf "argocd-app-loader: %s requires %s, but dependencies.%s is null, which removes it; list it with its package instead" $a.label $req $req) -}}
        {{- end -}}
        {{- fail (printf "argocd-app-loader: %s requires %s, but no listed app is named so or provides it" $a.label $req) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- range $name := keys $apps | sortAlpha -}}
  {{- $a := get $apps $name -}}
  {{- if and $a.mine $a.on -}}
    {{- range $req := $a.requires -}}
      {{- $req = toString $req -}}
      {{- $candidates := get $providers $req -}}
      {{- $met := list -}}
      {{- $off := list -}}
      {{- range $cand := $candidates -}}
        {{- $ca := get $apps $cand -}}
        {{- if $ca.on }}{{ $met = append $met $cand }}{{ else }}{{ $off = append $off (default $ca.label $ca.offLabel) }}{{ end -}}
      {{- end -}}
      {{- if not $met -}}
        {{- fail (printf "argocd-app-loader: %s requires %s, but nothing that is on provides it (off: %s)" $name $req (join ", " $off)) -}}
      {{- end -}}
      {{- $early := false -}}
      {{- range $m := $met -}}
        {{- $o := get $apps $m -}}
        {{- if or (lt $o.pw $a.pw) (and (eq $o.pw $a.pw) (or (ne $o.package $a.package) (le $o.aw $a.aw))) }}{{ $early = true }}{{ end -}}
      {{- end -}}
      {{- if not $early -}}
        {{- $o := get $apps (first $met) -}}
        {{- fail (printf "argocd-app-loader: %s requires %s, which %s provides only later (package wave %d, app wave %d; %s is at %d, %d)" $name $req $o.label $o.pw $o.aw $name $a.pw $a.aw) -}}
      {{- end -}}
    {{- end -}}
  {{- else if $a.mine -}}
    {{- /* Off: nothing that is on may still need it, or the removal would break it. */ -}}
    {{- range $n := prepend $a.provides $name -}}
      {{- $n = toString $n -}}
      {{- $others := list -}}
      {{- range $cand := get $providers $n -}}
        {{- if and (ne $cand $name) (get $apps $cand).on }}{{ $others = append $others $cand }}{{ end -}}
      {{- end -}}
      {{- if not $others -}}
        {{- $dependents := list -}}
        {{- range $other := keys $apps | sortAlpha -}}
          {{- $o := get $apps $other -}}
          {{- if and $o.on (has $n $o.requires) }}{{ $dependents = append $dependents $o.label }}{{ end -}}
        {{- end -}}
        {{- if $dependents -}}
          {{- $one := eq (len $dependents) 1 -}}
          {{- fail (printf "argocd-app-loader: %s is off, but %s require%s %s — switch %s off first, or switch %s back on" $name (join ", " $dependents) (ternary "s" "" $one) (ternary "it" (printf "%s, which only it provides" $n) (eq $n $name)) (ternary "it" "them" $one) $name) -}}
        {{- end -}}
      {{- end -}}
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
