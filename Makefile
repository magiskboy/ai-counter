# AI-counter — orchestrator cho cursor-agent + z8l upload.
# `make` (không tham số) in danh sách lệnh. Mọi biến dưới đây override được:
#   make up SANDBOX=~/khac NAME=ai2 ENGINE=docker
#
# ---------------------------------------------------------------------------
# Biến cấu hình
# ---------------------------------------------------------------------------
SANDBOX ?= $(HOME)/.sandbox-ai-counter
NAME    ?= ai-counter
IMAGE   ?= ai-counter:latest
# Engine: dùng podman nếu có, ngược lại docker. Override: ENGINE=docker
ENGINE  ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
# Để trống. Đặt SUDO=sudo nếu chown sandbox cần quyền root: make chown SUDO=sudo
SUDO    ?=

# Đường dẫn trong container + rút gọn lệnh exec
# Forward CURSOR_API_KEY vào container nếu host có export (cho lần chạy tay).
CURSOR_ENV = $(if $(CURSOR_API_KEY),-e CURSOR_API_KEY,)
RUN_DAILY  = /opt/ai-counter/docker/run-daily.sh
EXEC       = $(ENGINE) exec -u counter $(CURSOR_ENV) $(NAME)
LOGS_DIR   = $(SANDBOX)/ai-counter/logs

# Env truyền xuống các script (chúng tự đọc các biến này)
export SANDBOX NAME IMAGE

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Setup (lần đầu)
# ---------------------------------------------------------------------------
.PHONY: setup bootstrap chown build login cursor-login

setup: bootstrap chown build ## Setup lần đầu: bootstrap + chown + build (chưa login/up)
	@echo ""
	@echo "Setup xong. Bước tiếp theo:"
	@echo "  1. make login                 # auth z8l trên host (cần trình duyệt)"
	@echo "  2. export CURSOR_API_KEY=...   # và CONTEXT7_API_KEY nếu dùng MCP"
	@echo "  3. make up                    # khởi động container"

bootstrap: ## Tạo/khởi tạo sandbox HOME (biến SANDBOX)
	@echo "→ bootstrap sandbox: $(SANDBOX)"
	./sandbox/bootstrap.sh "$(SANDBOX)"

chown: ## Đổi owner sandbox sang uid 1000 (đặt SUDO=sudo nếu cần root)
	@echo "→ chown sandbox: $(SANDBOX)"
	$(SUDO) ./scripts/chown-sandbox.sh "$(SANDBOX)"

build: ## Build image (biến IMAGE, tự chọn podman/docker)
	@echo "→ build image: $(IMAGE)"
	./docker/build.sh

login: ## Auth z8l + cursor trên host (HOME=sandbox, idempotent)
	@echo "→ auth z8l + cursor (HOME=$(SANDBOX))"
	SANDBOX="$(SANDBOX)" ./sandbox/auth.sh "$(SANDBOX)"

cursor-login: ## Login cursor-agent TRONG container (khi host không có cursor-agent)
	@echo "→ cursor-agent login trong $(NAME) (lưu vào sandbox đã mount)"
	$(ENGINE) exec -u counter -it "$(NAME)" cursor-agent login

# ---------------------------------------------------------------------------
# Vòng đời container
# ---------------------------------------------------------------------------
.PHONY: up down restart rebuild

up: ## Khởi động container (đồng bộ timezone host)
	@echo "→ start $(NAME) ($(ENGINE), sandbox=$(SANDBOX))"
	@if [ "$(ENGINE)" = "podman" ]; then ./scripts/podman-run.sh; else ./scripts/docker-run.sh; fi

down: ## Dừng và xóa container
	@echo "→ stop + rm $(NAME)"
	-$(ENGINE) rm -f "$(NAME)"

restart: down up ## Down rồi up lại container

rebuild: build down up ## Build lại image rồi restart container

# ---------------------------------------------------------------------------
# Vận hành
# ---------------------------------------------------------------------------
.PHONY: daily dry-run logs cron-logs shell status

daily: ## Chạy pipeline daily ngay trong container
	@echo "→ run-daily ($(NAME))"
	$(EXEC) $(RUN_DAILY)

dry-run: ## Chạy daily ở chế độ dry-run (validate, không gọi agent)
	@echo "→ run-daily --dry-run ($(NAME))"
	$(EXEC) $(RUN_DAILY) --dry-run

logs: ## Tail log daily mới nhất trên host
	@echo "→ tail $(LOGS_DIR)/daily-*.log"
	@tail -f $(LOGS_DIR)/daily-*.log

cron-logs: ## Tail log cron trên host
	@echo "→ tail $(LOGS_DIR)/cron.log"
	@tail -f "$(LOGS_DIR)/cron.log"

shell: ## Mở bash trong container (user counter)
	$(ENGINE) exec -u counter -it "$(NAME)" bash

status: ## Trạng thái: container + giờ + z8l auth
	@echo "→ container:"
	@$(ENGINE) ps --filter "name=$(NAME)" || true
	@echo "→ giờ container:"
	-$(EXEC) date
	@echo "→ z8l auth:"
	-$(EXEC) z8l auth status

# ---------------------------------------------------------------------------
# Dev (chạy local, không cần container)
# ---------------------------------------------------------------------------
.PHONY: dev-dry-run test

dev-dry-run: ## Chạy daily --dry-run local qua uv (HOME=sandbox)
	HOME="$(SANDBOX)" uv run ai-counter daily --dry-run

test: ## Chạy integration test
	./scripts/integration-test.sh

# ---------------------------------------------------------------------------
# Khác
# ---------------------------------------------------------------------------
.PHONY: clean help

clean: down ## Down container + xóa image (hỏi xác nhận)
	@printf "Xóa image $(IMAGE)? [y/N] " && read ans && [ "$$ans" = "y" ] && $(ENGINE) rmi "$(IMAGE)" || echo "Bỏ qua."

help: ## In danh sách lệnh
	@echo "AI-counter — make <target>   (SANDBOX=$(SANDBOX), ENGINE=$(ENGINE))"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
