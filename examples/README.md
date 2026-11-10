# Examples

Each example is small and shows one shape. `make check` renders them against this checkout and
compares the result with `test/golden/` (see [test/README.md](../test/README.md)). Their charts
pull the loader through `file://`, which works only inside this repo; a real consumer pulls a
published version (see **Quick start** in the [README](../README.md)).

| Example | Shape |
|---|---|
| `consumer` | a single chart: apps, toggles, mirrors and a dependency entry in one `values.yaml` |
| `catalogue` | a catalogue: `values.yaml` holds the packages, their apps and the dependency list; `packages/core` is one package |
| `fleet` | a fleet repo: the root of roots (`root`) and one cluster's values (`clusters/demo`), read over the catalogue's |

## consumer

| App | Shows |
|---|---|
| `hello` | the smallest app: its own chart, one source |
| `wrapped` | an upstream chart from an OCI registry beside a local chart without dependencies: the values file's `chart:` block goes to the upstream chart, the rest to the local one |
| `wraponly` | an upstream chart alone: no `Chart.yaml`, so no second source |
| `httpchart` | an upstream chart from an HTTP Helm repo |
| `gitchart` | a chart inside a git repo: `chart.path` makes it one, and `chart.version` is the git ref |
| `patched` | the Kustomize form: `kustomize/` renders the upstream chart and patches what its values can't change |

`cluster.mirrors` names a table entry for each upstream with every method off, so the render shows
the public URLs; switching a method on moves the matching sources to the mirror. `patched`
requires `hello` in the dependency list: switching `hello` off while `patched` is on fails the
render instead of pruning `hello`.

## catalogue and fleet

The catalogue lists two packages: `core`, in its own repo under `packages/core`, and `media`, in
another repo. The cluster `demo` picks both, pins `media` to a tag, and adds `site`, a package in
the fleet repo that has no apps yet. In the dependency list `hello` provides `greeting` and
`needs-hello` requires it, so switching `hello` off while `needs-hello` is on fails `core`'s
render.
