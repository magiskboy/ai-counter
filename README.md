# AI-counter

Orchestrator chạy **cursor-agent** tự động trong container **Docker/Podman**, đồng bộ và upload session lên **Zen8labs AI Hub** qua **z8l**.

Sandbox trên máy host được mount vào `/home/counter` (user `counter`). Mọi credential và state nằm trên sandbox — không bake vào image.

**Yêu cầu:** Docker hoặc Podman, `bin/z8l` trong repo, đã đăng nhập **z8l** (Zen8labs SSO), **cursor-agent login** trong container.

> Podman rootless / SELinux (Fedora): [README.podman.md](README.podman.md)

---

## Cài đặt nhanh

**Một dòng** (clone → `~/.ai-counter`, sandbox → `~/.sandbox-ai-counter`, không cần `.env`):

```bash
curl -fsSL https://raw.githubusercontent.com/magiskboy/ai-counter/main/install.sh | bash
```

Hoặc từ repo đã clone:

```bash
./install.sh
```

Đường dẫn cố định: repo `~/.ai-counter`, sandbox `~/.sandbox-ai-counter`, container `ai-counter`.

Sau khi cài, đăng nhập một lần:

```bash
HOME=~/.sandbox-ai-counter ~/.ai-counter/bin/z8l auth login
podman exec -u counter -it ai-counter cursor-agent login   # hoặc docker exec ...
~/.ai-counter/scripts/doctor.sh
```

Runtime **podman** được ưu tiên nếu có; không thì **docker**.

### Tuỳ chọn `install.sh`

| Flag | Ý nghĩa |
|------|---------|
| `--no-start` | Không khởi động container |
| `--skip-build` | Bỏ build image |
| `--skip-skills` | Bỏ cài agent skills (npx) |
| `--skip-clone` | Dùng checkout `~/.ai-counter` có sẵn |
| `--runtime docker\|podman\|auto` | Chọn runtime |

---

## Tổng quan

```
Host $SANDBOX/  ──mount──►  /home/counter  (container HOME)
                              ├── ai-counter/config.yaml
                              ├── ai-counter/prompts/daily.yaml
                              ├── projects/
                              ├── .cursor/
                              ├── .agents/skills/
                              └── .z8l/cli/
```

**Luồng hàng ngày:** `cursor-agent` → `z8l sync` → `z8l upload`.

---

## Dùng hàng ngày

```bash
# Chạy pipeline ngay
docker exec -u counter ai-counter /opt/ai-counter/docker/run-daily.sh

# Shell trong container
docker exec -u counter -it ai-counter bash

# Upload một project (thay my-app bằng tên trong config)
docker exec -u counter -w /home/counter/projects/my-app ai-counter z8l upload

# Log (trên host)
tail -f ~/.sandbox-ai-counter/ai-counter/logs/daily-*.log
```

**Cron:** Thứ 2–6 **06:30** giờ Việt Nam (`Asia/Ho_Chi_Minh`, cố định).

**Chạy lại container** (sau cài): `./install.sh` hoặc `~/.ai-counter/scripts/podman-run.sh`.

---

## Cấu hình (`$SANDBOX/ai-counter/config.yaml`)

Chỉnh file này **không cần rebuild image**. Seed: `sandbox/ai-counter/config.yaml`.

**Thêm project:** clone repo vào `~/.sandbox-ai-counter/projects/<tên>` rồi khai báo trong `config.yaml`:

```bash
git clone git@github.com:you/my-app.git ~/.sandbox-ai-counter/projects/my-app
```

```yaml
sandbox:
  projects_dir: projects
  projects:
    - name: my-app
      conversations_per_day: 4
      user_messages_per_conversation: 3
```

- `sessions_per_day` là alias của `conversations_per_day`.
- Prompt: `$SANDBOX/ai-counter/prompts/daily.yaml` — chỉnh trên host, **không** cần rebuild image (seed: `sandbox/ai-counter/prompts/`).

### Agent skills (global hoặc theo project)

```yaml
skills:
  default_repo: https://github.com/obra/superpowers
  global_packages:
    - repo: https://github.com/obra/superpowers
      skills: [brainstorming]
sandbox:
  projects:
    - name: my-app
      skills: [systematic-debugging]
```

Cài thủ công: `SANDBOX=~/.sandbox-ai-counter ./scripts/install-sandbox-skills.sh`

### Lịch

```yaml
schedule:
  cron: "30 6 * * 1-5"   # 06:30 T2–T6, TZ Asia/Ho_Chi_Minh (cố định trong container)
```

---

## Lưu ý

| # | Nội dung |
|---|----------|
| 1 | Mount: `-v "$SANDBOX:/home/counter"` — mọi `exec` dùng `-u counter`. |
| 2 | Sandbox writable uid **1000**: `./scripts/chown-sandbox.sh "$SANDBOX"`. |
| 3 | **z8l auth** chỉ trên host hoặc copy `supabase-auth.json`. |
| 4 | **Cursor:** `cursor-agent login` trong container (không OAuth z8l trong container). |
| 5 | SELinux / Podman: [README.podman.md](README.podman.md). |
| 6 | `HOME is not writable` → chown sandbox + `--userns=keep-id` (Podman). |

---

## Thiếu `bin/z8l`?

```bash
export Z8L_DOWNLOAD_URL='https://.../z8l_Linux_x86_64.zip?token=...'
./scripts/vendor-z8l.sh
```

---

## Phát triển local (không container)

```bash
cp .env.example .env
export SANDBOX=~/.sandbox-ai-counter
HOME="$SANDBOX" uv run ai-counter daily --dry-run
./scripts/integration-test.sh
```
