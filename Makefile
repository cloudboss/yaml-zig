PROJECT = $(shell basename ${PWD})
DIR_ROOT = $(realpath $(CURDIR))
DIR_OUT = _output

ZIG_VERSION = 0.15.2
CTR_IMAGE_BASE = alpine:3.21

UID = $(shell id -u)
GID = $(shell id -g)
UID_SHA256 = $(shell echo -n $(UID) | sha256sum | awk '{print $$1}')
GID_SHA256 = $(shell echo -n $(GID) | sha256sum | awk '{print $$1}')
CTR_IMAGE_BASE_SHA256 = $(shell echo -n $(CTR_IMAGE_BASE) | sha256sum | awk '{print $$1}')
ZIG_VERSION_SHA256 = $(shell echo -n $(ZIG_VERSION) | sha256sum | awk '{print $$1}')
DOCKERFILE_SHA256 = $(shell sha256sum Dockerfile.build | awk '{print $$1}')
DOCKER_INPUTS_SHA256 = $(shell echo -n $(UID_SHA256)$(GID_SHA256)$(CTR_IMAGE_BASE_SHA256)$(ZIG_VERSION_SHA256)$(DOCKERFILE_SHA256) | \
	sha256sum | awk '{print $$1}' | cut -c 1-40)
CTR_IMAGE_LOCAL = $(PROJECT):$(DOCKER_INPUTS_SHA256)
HAS_IMAGE_LOCAL = $(DIR_OUT)/.image-local-$(DOCKER_INPUTS_SHA256)

ZIG_BUILD_FLAGS = --cache-dir $(DIR_OUT)/zig-cache --global-cache-dir $(DIR_OUT)/zig-cache --prefix $(DIR_OUT)/zig-out

.DEFAULT_GOAL = build

$(DIR_OUT):
	@mkdir -p $(DIR_OUT)

$(DIR_OUT)/%/:
	@mkdir -p $(DIR_OUT)/$*

$(HAS_IMAGE_LOCAL): | $(DIR_OUT)/dockerbuild/
	@docker build \
		--build-arg FROM=$(CTR_IMAGE_BASE) \
		--build-arg GID=$(GID) \
		--build-arg UID=$(UID) \
		--build-arg ZIG_VERSION=$(ZIG_VERSION) \
		-f $(DIR_ROOT)/Dockerfile.build \
		-t $(CTR_IMAGE_LOCAL) \
		$(DIR_OUT)/dockerbuild
	@touch $(HAS_IMAGE_LOCAL)

build: $(HAS_IMAGE_LOCAL)
	@docker run --rm \
		-v $(DIR_ROOT):/code \
		-w /code \
		--security-opt label=type:container_runtime_t \
		$(CTR_IMAGE_LOCAL) /bin/sh -c "zig build $(ZIG_BUILD_FLAGS)"

test: $(HAS_IMAGE_LOCAL)
	@docker run --rm \
		-v $(DIR_ROOT):/code \
		-w /code \
		--security-opt label=type:container_runtime_t \
		$(CTR_IMAGE_LOCAL) /bin/sh -c "zig build test $(ZIG_BUILD_FLAGS)"

docs: $(HAS_IMAGE_LOCAL)
	@docker run --rm \
		-v $(DIR_ROOT):/code \
		-w /code \
		--security-opt label=type:container_runtime_t \
		$(CTR_IMAGE_LOCAL) /bin/sh -c "zig build docs $(ZIG_BUILD_FLAGS)"

clean:
	@rm -rf $(DIR_OUT)

.PHONY: build test docs clean
