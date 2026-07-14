.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help build up down restart logs shell claude-login opencode clean nuke

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env — edit it, then run 'make up'")

build: ## Build the image
	docker compose build

up: env ## Start the box (builds if needed)
	docker compose up -d --build
	@echo "opencode web:  http://localhost:$$(grep -E '^OPENCODE_PORT=' .env | cut -d= -f2 || echo 4096)"
	@echo "code-server:   http://localhost:$$(grep -E '^CODE_SERVER_PORT=' .env | cut -d= -f2 || echo 4097)"

down: ## Stop and remove the box (keeps volumes)
	docker compose down

restart: ## Restart the box
	docker compose restart

logs: ## Follow logs
	docker compose logs -f

shell: ## Open a bash shell inside the box
	docker compose exec opencode-box bash

claude-login: ## Interactive Claude Max login inside the box (alternative to CLAUDE_CODE_OAUTH_TOKEN)
	docker compose exec -it opencode-box claude auth login

opencode: ## Attach an opencode TUI to the running web server
	docker compose exec opencode-box opencode attach "http://localhost:$$(grep -E '^OPENCODE_PORT=' .env | cut -d= -f2 || echo 4096)"

clean: ## Stop the box (keeps volumes)
	docker compose down

nuke: ## Stop and DELETE all volumes (projects, docker data, home) — destructive
	docker compose down -v
