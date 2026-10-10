# Colon developer tasks. `make help` lists them.
# Pass NATIVE=1 to build only for this Mac's architecture (faster than universal).

SHELL := /bin/bash
APP_FLAGS := $(if $(NATIVE),--native,)

.DEFAULT_GOAL := app
.PHONY: help build app install dmg test clean emoji-data icon

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[1m%-11s\033[0m %s\n", $$1, $$2}'

build: ## Debug build with SwiftPM
	swift build

app: ## Build and sign build/Colon.app (universal release)
	scripts/build-app.sh $(APP_FLAGS)

install: ## Build, install to /Applications and launch
	scripts/install.sh $(APP_FLAGS)

dmg: app ## Build dist/Colon-<version>.dmg
	scripts/make-dmg.sh

test: ## Run the unit tests
	swift test

clean: ## Remove all build products
	swift package clean
	rm -rf .build build dist

emoji-data: ## Regenerate Sources/ColonCore/Resources/emoji.json and i18n/
	python3 scripts/build-emoji-data.py

icon: ## Regenerate the app icon in Resources/
	swift scripts/make-icon.swift
