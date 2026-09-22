.DEFAULT_GOAL := help

IMAGE ?= api2studio/workflow-sandbox
override TAG := $(strip $(shell cat version.txt))
# Leave empty to build for the Docker daemon's architecture.
PLATFORM ?=

.PHONY: help check-version build push

help:
	@printf '%s\n' \
	  'make build                 Build with version.txt and latest tags' \
	  'make push                  Build, then push both tags to Docker Hub' \
	  'make build PLATFORM=linux/amd64  Build for a specific platform' \
	  'Default image: api2studio/workflow-sandbox; edit version.txt to set the version' \
	  'Before pushing, run: docker login'

check-version:
	@test -n "$(TAG)" || { echo 'version.txt must contain an image version' >&2; exit 1; }

build: check-version
	docker build $(if $(PLATFORM),--platform "$(PLATFORM)") --tag "$(IMAGE):$(TAG)" --tag "$(IMAGE):latest" .

push: build
	docker push "$(IMAGE):$(TAG)"
	docker push "$(IMAGE):latest"
