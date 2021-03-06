NAME    := unsee
VERSION := $(shell git describe --tags --always --dirty='-dev')

# Alertmanager instance used when running locally, points to mock data
MOCK_PATH         := $(CURDIR)/internal/mock/0.11.0
ALERTMANAGER_URIS := "mock:file://$(MOCK_PATH)"
# Listen port when running locally
PORT := 8080

SOURCES       := $(wildcard *.go) $(wildcard */*.go) $(wildcard */*/*.go)
ASSET_SOURCES := $(wildcard assets/*/* assets/*/*/*)

GO_BINDATA_MODE := prod
GIN_DEBUG := false
ifdef DEBUG
	GO_BINDATA_FLAGS = -debug
	GO_BINDATA_MODE  = debug
	GIN_DEBUG = true
	DOCKER_ARGS = -v $(CURDIR)/assets:$(CURDIR)/assets:ro
endif

.DEFAULT_GOAL := $(NAME)

.build/go-bindata:
	@mkdir -p .build
	go get -u github.com/jteeuwen/go-bindata/...
	touch $@

.build/go-bindata-assetfs:
	@mkdir -p .build
	go get -u github.com/elazarl/go-bindata-assetfs/...
	touch $@

.build/golint:
	@mkdir -p .build
	go get -u github.com/golang/lint/golint
	touch $@

.build/npm.install: package.json package-lock.json
	npm install
	touch $@

.build/deps.ok: .build/go-bindata .build/go-bindata-assetfs .build/golint .build/npm.install
	@mkdir -p .build
	touch $@

.build/bindata_assetfs.%:
	@mkdir -p .build
	rm -f .build/bindata_assetfs.*
	touch $@

bindata_assetfs.go: .build/deps.ok .build/bindata_assetfs.$(GO_BINDATA_MODE) $(ASSET_SOURCES) webpack.config.js .build/vendor.ok
	$(CURDIR)/node_modules/.bin/webpack
	go-bindata-assetfs $(GO_BINDATA_FLAGS) -prefix assets -nometadata assets/templates/... assets/static/dist/...

$(NAME): .build/deps.ok .build/vendor.ok bindata_assetfs.go $(SOURCES)
	go build -ldflags "-X main.version=$(VERSION)"

.PHONY: clean
clean:
	rm -fr .build $(NAME)

.PHONY: run
run: $(NAME)
	ALERTMANAGER_URIS=$(ALERTMANAGER_URIS) \
	COLOR_LABELS_UNIQUE="@receiver instance cluster" \
	COLOR_LABELS_STATIC="job" \
	DEBUG="$(GIN_DEBUG)" \
	FILTER_DEFAULT="@state=active" \
	PORT=$(PORT) \
	./$(NAME)

.PHONY: docker-image
docker-image:
	docker build --build-arg VERSION=$(VERSION) -t $(NAME):$(VERSION) .

.PHONY: run-docker
run-docker: docker-image
	@docker rm -f $(NAME) || true
	docker run \
	    --name $(NAME) \
	    $(DOCKER_ARGS) \
	    -v $(MOCK_PATH):$(MOCK_PATH) \
	    -e ALERTMANAGER_URIS=$(ALERTMANAGER_URIS) \
	    -e COLOR_LABELS_UNIQUE="instance cluster" \
	    -e COLOR_LABELS_STATIC="job" \
	    -e DEBUG="$(GIN_DEBUG)" \
	    -e PORT=$(PORT) \
	    -p $(PORT):$(PORT) \
	    $(NAME):$(VERSION)

.PHONY: lint
lint: .build/deps.ok
	golint ./... | (egrep -v "^vendor/|^bindata_assetfs.go" || true)
	$(CURDIR)/node_modules/.bin/eslint --quiet assets/static/*.js

.PHONY: test
test: lint bindata_assetfs.go
	go test -bench=. -cover `go list ./... | grep -v /vendor/`
	npm test

.build/dep.ok:
	go get -u github.com/golang/dep/cmd/dep
	@mkdir -p .build
	touch $@

.build/vendor.ok: Gopkg.lock Gopkg.toml .build/dep.ok
	dep ensure
	dep prune
	touch $@

.PHONY: vendor
vendor: .build/dep.ok
	dep ensure
	dep prune


.PHONY: vendor-update
vendor-update: .build/dep.ok
	dep ensure -update
	dep prune
