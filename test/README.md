# Tests

`make check` lints the chart, runs the unit tests, renders every fixture against this checkout of
the loader, fails if a render differs from its committed file in `golden/`, and validates the
goldens. After a deliberate change, run `make golden`, review the diff, and commit it with the
change.

| Fixture | Rendered into | Source |
|---|---|---|
| `examples/consumer` | `golden/example.yaml` | a single chart (no packages) |
| `examples/fleet/root` + `examples/catalogue/values.yaml` + `examples/fleet/clusters/demo/values.yaml` | `golden/fleet.yaml` | a root of roots: packages in the catalogue, in another repo, in the fleet repo |
| `examples/catalogue/packages/core` + `examples/catalogue/values.yaml` + `examples/fleet/clusters/demo/values.yaml` | `golden/catalogue-core.yaml` | one of the catalogue's packages, as its Application renders it (`argocdAppLoader.source` and `package` set as the root would) |

Each example is small and shows one shape; the unit tests pin single behaviours, one fixture app
each.

## Unit tests

`make unit` runs the [helm-unittest](https://github.com/helm-unittest/helm-unittest) suites in
`unit/tests/`. A library chart can't be tested on its own, so `unit/` is a consumer whose fixture
apps sit under `unit/apps/unit/`, each switched on only by the tests that need it; the group and
`appsRoot` tests use roots of their own beside it (`grouped`, `groups`, `groups-typo`,
`invalid-groups`, `nested/apps`, `nested2/apps`). Golden renders
show what changed; unit tests pin behaviour the goldens can't show, such as a render that must fail.

## Schema check

`make validate` runs `kubeconform -strict` over the goldens, against the Application and
AppProject JSON Schemas from [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog)
(commit 3eb90d4), stored in `schemas/` so the check runs offline; replace them on purpose to move
to newer ones. It catches what renders fine but Argo CD would reject or ignore: a misspelt `spec`
field, or `null` where a list belongs (the old `syncOptions: null`). The schemas don't constrain
`metadata`, and `valuesObject` is free-form, so neither is checked.
