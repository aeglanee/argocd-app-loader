{{- /*
  argocd-app-loader.dependencies — the dependency list, checked in every package's own render.
  Each package renders and syncs on its own, so a check only stops a deletion if it runs inside
  the package that would delete. The list sits in values every package reads (the catalogue's
  values.yaml), so each one sees every dependency, also those of apps in other packages:

      argocdAppLoader:
        dependencies:
          harbor:
            requires: [cnpg, storage.replicated]   # app names, or what some app provides:
          longhorn:
            provides: [storage.replicated]

  With packages, cluster.packages.<p>.apps says where each app is, and every app in it counts as
  listed; in a single chart only the entries are listed (opt-in). A
  listed app is on when its package is picked and it is on there (isOn). Each package checks only
  its own apps, and fails when:
    - one that is on requires something no app that is on is named or provides;
    - one that is off is required (by name, or for something only it provides) by an app that is
      on, anywhere; so nothing is pruned until the dependents are off too;
    - a requirement comes later: from a later package wave, or inside one package a later app
      wave (the same wave passes);
    - a required name isn't known at all (a typo, or an entry removed while something on still
      requires it; this fails every render, also the one that would prune), an entry names an app
      no package lists or still sets package:;
    - a package's app list and its folders disagree, or an override names an app of another
      package or none (the root checks every package's).

  Limits: a package pinned to a version checks the list at that version; removing a provider and
  its dependents in one commit passes, and the packages then prune in parallel, so switch the
  dependents off first. Duplicate names of groups across packages aren't seen.

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
    {{- fail (printf "argocd-app-loader: dependencies.%s must be a mapping (requires, provides), got %s" $n (kindOf $e)) -}}
  {{- else -}}
    {{- $_ := set $deps $n $e -}}
  {{- end -}}
{{- end -}}
{{- /* Every app a package lists counts as listed, in that package; a null entry of one only
       drops its requires and provides. */ -}}
{{- $appPkg := include "argocd-app-loader.appPackages" $V | fromYaml -}}
{{- range $a := keys $appPkg -}}
  {{- if not (hasKey $deps $a) }}{{ $_ := set $deps $a (dict) }}{{ end -}}
{{- end -}}
{{- /* A package always checks its folders against its app list, even with nothing listed. */ -}}
{{- if or $deps $cfg.package -}}
{{- $all := default false .all -}}
{{- $self := ternary "" (toString (default "" $cfg.package)) $all -}}
{{- $c := default dict $V.cluster -}}

{{- /* Packages: picked or not, and their wave. The one being rendered is picked. */ -}}
{{- $pkgs := dict -}}
{{- range $n, $p := default dict $c.packages -}}
  {{- $_ := set $pkgs $n (dict "on" (or (eq (include "argocd-app-loader.picked" $p) "true") (eq $n $self)) "wave" (int (default 0 (default dict $p).wave))) -}}
{{- end -}}
{{- range $n, $p := default dict $c.instancePackages -}}
  {{- $_ := set $pkgs $n (dict "on" true "wave" (int (default 0 (default dict $p).wave))) -}}
{{- end -}}

{{- /* A package's overrides must name one of its apps: a misplaced or misspelt one would do
       nothing. The root checks every package, a package its own. */ -}}
{{- range $pn := keys $pkgs | sortAlpha -}}
  {{- if or $all (eq $pn $self) -}}
    {{- $has := list -}}
    {{- range $a, $ap := $appPkg }}{{ if eq $ap $pn }}{{ $has = append $has $a }}{{ end }}{{ end -}}
    {{- $where := include "argocd-app-loader.scopedKey" (dict "Values" $V "package" $pn "key" "overrides") -}}
    {{- range $a, $v := include "argocd-app-loader.scoped" (dict "Values" $V "package" $pn "key" "overrides") | fromYaml -}}
      {{- if kindIs "invalid" $v }}{{ continue }}{{ end -}}{{- /* null: removed by a later file */ -}}
      {{- if ne (get $appPkg $a) $pn -}}
        {{- fail (printf "argocd-app-loader: %s.%s: %s" $where $a (ternary (printf "%s is in package %s" $a (get $appPkg $a)) (printf "package %s has no app %s (it has %s)" $pn $a (join ", " (sortAlpha $has))) (hasKey $appPkg $a))) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
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
  {{- if hasKey $e "package" -}}
    {{- fail (printf "argocd-app-loader: dependencies.%s.package: not needed, cluster.packages.<package>.apps says where %s is" $name $name) -}}
  {{- end -}}
  {{- $pkg := toString (default "" (get $appPkg $name)) -}}
  {{- if and (or $self (and $all $pkgs)) (not $pkg) -}}
    {{- fail (printf "argocd-app-loader: dependencies.%s: no package lists app %s (cluster.packages.<package>.apps)" $name $name) -}}
  {{- end -}}
  {{- range $key := list "requires" "provides" -}}
    {{- $v := index $e $key -}}
    {{- if not (or (kindIs "invalid" $v) (kindIs "slice" $v)) -}}
      {{- fail (printf "argocd-app-loader: dependencies.%s.%s must be a list, got %s" $name $key (kindOf $v)) -}}
    {{- end -}}
  {{- end -}}
  {{- $isMine := or (not $self) (eq $pkg $self) -}}
  {{- if and $isMine (not $all) (not (hasKey $mine $name)) -}}
    {{- if $pkg -}}
      {{- fail (printf "argocd-app-loader: %s lists %s, but the package has no folder for it (a typo?)" (include "argocd-app-loader.scopedKey" (dict "Values" $V "package" $pkg "key" "apps")) $name) -}}
    {{- end -}}
    {{- fail (printf "argocd-app-loader: dependencies.%s is listed, but this chart has no app %s" $name $name) -}}
  {{- end -}}
  {{- $pkgOn := true -}}
  {{- $pw := 0 -}}
  {{- if $pkg }}{{ $pkgOn = (get $pkgs $pkg).on }}{{ $pw = (get $pkgs $pkg).wave }}{{ end -}}
  {{- $on := and $pkgOn (eq (include "argocd-app-loader.isOn" (dict "Values" $V "name" $name "package" $pkg)) "true") -}}
  {{- $_ := set $apps $name (dict
        "package" $pkg "mine" $isMine "on" $on "pkgOn" $pkgOn
        "requires" (default list $e.requires) "provides" (default list $e.provides)
        "pw" $pw "aw" (ternary 0 (ternary (get $mine $name) 0 $isMine) $all)
        "label" (ternary $name (printf "%s (%s)" $name $pkg) (and (or $isMine (not $pkg)) (not $all)))
        "offLabel" (ternary (printf "%s (package %s isn't picked)" $name $pkg) "" (not $pkgOn))) -}}
{{- end -}}
{{- if $self -}}
  {{- range $name := keys $mine | sortAlpha -}}
    {{- $a := get $apps $name -}}
    {{- if not $a -}}
      {{- fail (printf "argocd-app-loader: app %s has a folder in package %s, but %s doesn't list it" $name $self (include "argocd-app-loader.scopedKey" (dict "Values" $V "package" $self "key" "apps"))) -}}
    {{- else if not $a.mine -}}
      {{- fail (printf "argocd-app-loader: app %s has a folder in package %s, but it is listed under package %s" $name $self $a.package) -}}
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
          {{- fail (printf "argocd-app-loader: %s requires %s, but dependencies.%s is null, which removes it; list it again (an empty map is enough)" $a.label $req $req) -}}
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
  argocd-app-loader.isOn — "true" if the app's toggle switches it on: in a package,
  cluster.packages.<package>.apps.<name> (the catalogue's usual value, or the cluster's); in a
  single chart, cluster.apps.<name>. A bool is taken as written. Anything else counts as on if it isn't empty,
  or, with argocdAppLoader.requireToggle: false, always. NOT `default true`: sprig's default
  treats an explicit false as empty. It doesn't look at whether the package is picked: values
  files ask argocd-app-loader.running.
*/ -}}
{{- define "argocd-app-loader.isOn" -}}
{{- $cfg := default dict .Values.argocdAppLoader -}}
{{- $requireToggle := ternary $cfg.requireToggle true (kindIs "bool" $cfg.requireToggle) -}}
{{- $toggle := index (include "argocd-app-loader.scoped" (dict "Values" .Values "package" .package "key" "apps") | fromYaml) .name -}}
{{- $on := true -}}
{{- if kindIs "bool" $toggle -}}
  {{- $on = $toggle -}}
{{- else if $requireToggle -}}
  {{- $on = not (empty $toggle) -}}
{{- end -}}
{{- ternary "true" "false" $on -}}
{{- end -}}

{{- /*
  argocd-app-loader.scoped — a package's own toggles or overrides ("key": apps | overrides), as
  YAML: cluster.packages.<package>.<key> (or cluster.instancePackages.<package>.<key>); without a
  package (a single chart), cluster.<key>.
*/ -}}
{{- define "argocd-app-loader.scoped" -}}
{{- $c := default dict .Values.cluster -}}
{{- $m := index $c .key -}}{{- /* index, not get: get gives "" for a missing key */ -}}
{{- if .package -}}
  {{- $instance := hasKey (default dict $c.instancePackages) .package -}}
  {{- $p := index (ternary (default dict $c.instancePackages) (default dict $c.packages) $instance) .package -}}
  {{- if not (or (kindIs "invalid" $p) (kindIs "map" $p)) -}}
    {{- fail (printf "argocd-app-loader: cluster.%s.%s must be a map, {enabled: true} or {enabled: false}, got %v (a %s)" (ternary "instancePackages" "packages" $instance) .package $p (kindOf $p)) -}}
  {{- end -}}
  {{- $m = index (default dict $p) .key -}}
{{- end -}}
{{- /* Checked here: through toYaml/fromYaml a list or a bool would come back as an empty map. */ -}}
{{- if not (or (kindIs "invalid" $m) (kindIs "map" $m)) -}}
  {{- fail (printf "argocd-app-loader: %s must be a map of <app>: ..., got %v (a %s)" (include "argocd-app-loader.scopedKey" .) $m (kindOf $m)) -}}
{{- end -}}
{{- toYaml (default dict $m) -}}
{{- end -}}

{{- /* argocd-app-loader.scopedKey — where scoped reads, for messages. */ -}}
{{- define "argocd-app-loader.scopedKey" -}}
{{- if .package -}}
  {{- printf "cluster.%s.%s.%s" (ternary "instancePackages" "packages" (hasKey (default dict (default dict .Values.cluster).instancePackages) .package)) .package .key -}}
{{- else -}}
  {{- printf "cluster.%s" .key -}}
{{- end -}}
{{- end -}}

{{- /* argocd-app-loader.noFlatToggles — with packages, toggles and overrides sit under the
       package; flat ones would do nothing. Input: .Values.cluster. */ -}}
{{- define "argocd-app-loader.noFlatToggles" -}}
{{- range $old := list "apps" "overrides" -}}
  {{- if get (default dict $) $old -}}
    {{- fail (printf "argocd-app-loader: cluster.%s: with packages, set cluster.packages.<package>.%s" $old $old) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- /* argocd-app-loader.picked — "true" if a pick (cluster.packages.<name>) picks the package. */ -}}
{{- define "argocd-app-loader.picked" -}}
{{- ternary "true" "false" (and (kindIs "map" .) (kindIs "bool" .enabled) .enabled) -}}
{{- end -}}

{{- /*
  argocd-app-loader.appPackages — app name -> package, from cluster.packages.<p>.apps and
  cluster.instancePackages.<p>.apps, as YAML. Input: .Values.
*/ -}}
{{- define "argocd-app-loader.appPackages" -}}
{{- $out := dict -}}
{{- $c := default dict .cluster -}}
{{- range $kind := list "packages" "instancePackages" -}}
  {{- $list := default dict (get $c $kind) -}}
  {{- range $pn := keys $list | sortAlpha -}}
    {{- $p := get $list $pn -}}
    {{- if not (kindIs "map" $p) }}{{ continue }}{{ end -}}{{- /* the root and scoped say why */ -}}
    {{- range $a, $on := default dict $p.apps -}}
      {{- if kindIs "invalid" $on }}{{ continue }}{{ end -}}{{- /* null: removed by a later file */ -}}
      {{- if not (kindIs "bool" $on) -}}
        {{- fail (printf "argocd-app-loader: cluster.%s.%s.apps.%s must be true or false, got %v" $kind $pn $a $on) -}}
      {{- end -}}
      {{- with get $out $a }}{{ fail (printf "argocd-app-loader: app %s is listed under two packages, %s and %s; it belongs to the one whose folder holds it" $a . $pn) }}{{ end -}}
      {{- $_ := set $out $a $pn -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{- /*
  argocd-app-loader.running — "true" if an app runs on this cluster: the package that lists it is
  picked (or is the one being rendered, which only renders while picked), and the app is on. For values files: {{ if eq (include "argocd-app-loader.running" (dict "Values" .Values "name" "certs")) "true" }}
*/ -}}
{{- define "argocd-app-loader.running" -}}
{{- $appPkg := include "argocd-app-loader.appPackages" .Values | fromYaml -}}
{{- if not $appPkg -}}
  {{- /* A single chart without packages: its toggle. */ -}}
  {{- include "argocd-app-loader.isOn" (dict "Values" .Values "name" .name) -}}
{{- else -}}
{{- $pkg := get $appPkg .name | required (printf "argocd-app-loader: running: no package lists app %s (a typo?)" .name) -}}
{{- $c := default dict .Values.cluster -}}
{{- $self := toString (default "" (default dict .Values.argocdAppLoader).package) -}}
{{- $picked := or (eq $pkg $self) (hasKey (default dict $c.instancePackages) $pkg) (eq (include "argocd-app-loader.picked" (get (default dict $c.packages) $pkg)) "true") -}}
{{- ternary (include "argocd-app-loader.isOn" (dict "Values" .Values "name" .name "package" $pkg)) "false" $picked -}}
{{- end -}}
{{- end -}}

{{- /*
  argocd-app-loader.provided — "true" if an app that runs here (see running) lists the name under
  argocdAppLoader.dependencies.<app>.provides. For values files, to ask for a capability instead of
  an app: {{ if eq (include "argocd-app-loader.provided" (dict "Values" .Values "name" "tls")) "true" }}
*/ -}}
{{- define "argocd-app-loader.provided" -}}
{{- $found := false -}}
{{- $known := false -}}
{{- range $app, $e := default dict (default dict .Values.argocdAppLoader).dependencies -}}
  {{- if and (kindIs "map" $e) (has $.name (default list $e.provides)) -}}
    {{- $known = true -}}
    {{- if eq (include "argocd-app-loader.running" (dict "Values" $.Values "name" $app)) "true" }}{{ $found = true }}{{ end -}}
  {{- end -}}
{{- end -}}
{{- if not $known -}}
  {{- fail (printf "argocd-app-loader: provided: no app in the dependency list provides %s (a typo?)" .name) -}}
{{- end -}}
{{- ternary "true" "false" $found -}}
{{- end -}}
