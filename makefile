include tools.mk

SANDBOX := docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL \
	--security-opt no-new-privileges --user $(shell id -u):$(shell id -g) --env HOME=/tmp --workdir /src
CHECK := $(SANDBOX) --volume "$(CURDIR):/src:ro"
FIX := $(SANDBOX) --volume "$(CURDIR):/src"

GIT_COMMON_DIR := $(shell git rev-parse --path-format=absolute --git-common-dir)
TEXT := $(filter-out test/golden/% test/schemas/%,$(shell git grep -I --name-only -e ''))
YAML := $(shell git grep -I --name-only -e '' -- '*.yml' '*.yaml' ':(exclude,glob)**/templates/**' \
	':(exclude,glob)test/unit/**/invalid-*/**' ':(exclude)test/golden')
MARKDOWN := $(filter-out CHANGELOG.md,$(filter %.md,$(TEXT)))
FLOW_MAPPING := (:|^\s*-)\s+\{(?!\{)\s*[^{}\s\#"'"'"'][^{}]*?:\s
CRDS := test/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.PHONY: lint files actions secrets renovate markdown yaml shell check chart unit golden validate hooks

lint: files actions secrets renovate markdown yaml shell

files:
	$(CHECK) $(PRE_COMMIT_HOOKS) check-merge-conflict --assume-in-merge $(TEXT)
	$(CHECK) $(PRE_COMMIT_HOOKS) check-yaml $(YAML)
	$(FIX) $(PRE_COMMIT_HOOKS) end-of-file-fixer $(TEXT)
	$(FIX) $(PRE_COMMIT_HOOKS) trailing-whitespace-fixer --markdown-linebreak-ext=md $(TEXT)

actions:
	$(CHECK) $(ACTIONLINT)
	$(CHECK) $(ZIZMOR) .

secrets:
	$(CHECK) $(GITLEAKS) dir --redact --no-banner .

renovate:
	$(CHECK) $(RENOVATE_CONFIG_VALIDATOR) --strict .github/renovate.json

markdown:
	$(CHECK) $(MARKDOWNLINT) $(MARKDOWN)

yaml:
	$(CHECK) $(YAMLLINT) --strict .
	$(CHECK) --volume "$(GIT_COMMON_DIR):$(GIT_COMMON_DIR):ro" $(PRE_COMMIT_HOOKS) \
		git grep -nP '$(FLOW_MAPPING)' -- '*.yaml' '*.yml' '*.gotmpl' ':!test/golden'; test $$? -eq 1

shell:
	$(CHECK) --entrypoint /usr/local/bin/shellcheck $(ACTIONLINT) .githooks/pre-push

check: chart unit golden validate
	git diff --exit-code -- test/golden

chart:
	$(CHECK) $(HELM) lint .

unit:
	rm -rf test/unit/charts test/unit/Chart.lock
	$(FIX) $(HELM) dependency build test/unit > /dev/null
	$(FIX) $(HELM) unittest test/unit

golden:
	for chart in examples/consumer examples/fleet/root examples/catalogue/packages/core; do \
		rm -rf $$chart/charts $$chart/Chart.lock && $(FIX) $(HELM) dependency build $$chart > /dev/null || exit 1; \
	done
	$(CHECK) $(HELM) template cluster examples/consumer --namespace argocd > test/golden/example.yaml
	$(CHECK) $(HELM) template cluster examples/fleet/root --namespace argocd -f examples/catalogue/values.yaml \
		-f examples/fleet/clusters/demo/values.yaml > test/golden/fleet.yaml
	$(CHECK) $(HELM) template core examples/catalogue/packages/core --namespace argocd \
		-f examples/catalogue/values.yaml -f examples/fleet/clusters/demo/values.yaml \
		--set argocdAppLoader.source.repoURL=https://github.com/example/catalogue.git \
		--set argocdAppLoader.source.path=packages/core --set argocdAppLoader.package=core \
		> test/golden/catalogue-core.yaml

validate: golden
	$(CHECK) --entrypoint kubeconform $(HELM) -strict -summary -schema-location '$(CRDS)' test/golden/*.yaml

hooks:
	git config core.hooksPath .githooks
