# AI-counter

Orchestrator chạy **cursor-agent** tự động trong container **Docker**, đồng bộ và upload session lên **Zen8labs AI Hub** qua **z8l**.

Sandbox trên máy host được mount vào `/home/counter` (user `counter`). Mọi credential và state nằm trên sandbox — không bake vào image.

**Yêu cầu:** Docker Engine, `bin/z8l` trong repo, [`CURSOR_API_KEY`](https://cursor.com/settings), đã đăng nhập **z8l** (Zen8labs SSO).

> Dùng Podman (rootless, SELinux): [README.podman.md](README.podman.md)

---

## Tổng quan

```
Host $SANDBOX/  ──mount──►  /home/counter  (container HOME)
                              ├── ai-counter/config.yaml   # automation, skills, schedule
                              ├── projects/                # repo giả / project thật
                              ├── .cursor/                 # MCP, CLI config
                              ├── .agents/skills/          # agent skills (npx skills)
                              └── .z8l/cli/                # auth z8l
```

**Luồng hàng ngày:** `cursor-agent` chạy conversation theo config → `z8l sync` → `z8l upload`.

---

## Cài đặt (lần đầu)

```bash
git clone <url-repo>
cd AI-counter

export SANDBOX=~/ai-counter-sandbox
./sandbox/bootstrap.sh
./scripts/chown-sandbox.sh "$SANDBOX"

docker build -f docker/Dockerfile -t ai-counter:latest .
# hoặc: ./docker/build.sh   (dùng docker nếu không có podman)
```

### Đăng nhập z8l (trên host)

OAuth redirect không hoạt động trong container — **login trên host**:

```bash
HOME=$SANDBOX ./bin/z8l auth login

# hoặc copy token đã login sẵn:
cp ~/.z8l/cli/supabase-auth.json "$SANDBOX/.z8l/cli/"
chmod 600 "$SANDBOX/.z8l/cli/supabase-auth.json"
```

### Chạy container

Container dùng chung đồng hồ kernel với host; cần khớp **timezone** (cron, log, z8l).

**Khuyến nghị** — script tự lấy TZ host + mount `/etc/localtime`:

```bash
SANDBOX="$SANDBOX" ./scripts/docker-run.sh
```

**Thủ công:**

```bash
export TZ="${TZ:-$(timedatectl show -pTimezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)}"

docker run -d \
  --name ai-counter \
  --restart unless-stopped \
  -e TZ \
  -v "$SANDBOX:/home/counter" \
  -v /etc/localtime:/etc/localtime:ro \
  ai-counter:latest

docker exec -u counter ai-counter cursor-agent login   # hoặc chỉ dùng CURSOR_API_KEY
```

Đặt `schedule.timezone` trong `$SANDBOX/ai-counter/config.yaml` (ví dụ `Asia/Ho_Chi_Minh`). Biến `-e TZ` khi `docker run` ghi đè config.

**Fedora / SELinux:** thêm suffix `:z` hoặc `:Z` trên volume, ví dụ `-v "$SANDBOX:/home/counter:Z"`.

### Kiểm tra

```bash
date
docker exec -u counter ai-counter date

docker logs ai-counter
docker exec -u counter ai-counter z8l auth status
docker exec -u counter ai-counter /opt/ai-counter/docker/run-daily.sh --dry-run
```

---

## Dùng hàng ngày

```bash
# Chạy pipeline ngay
docker exec -u counter ai-counter /opt/ai-counter/docker/run-daily.sh

# Shell trong container
docker exec -u counter -it ai-counter bash

# Upload một project
docker exec -u counter -w /home/counter/projects/fake-api ai-counter z8l upload

# Log (trên host)
tail -f ~/ai-counter-sandbox/ai-counter/logs/daily-*.log
tail -f ~/ai-counter-sandbox/ai-counter/logs/cron.log
```

**Cron:** Thứ 2–6, **06:30** theo `schedule.timezone` trong config (mặc định `Asia/Ho_Chi_Minh` trong `sandbox/config.example.yaml`).

---

## Cấu hình (`$SANDBOX/ai-counter/config.yaml`)

Chỉnh file này **không cần rebuild image**. Copy từ `sandbox/config.example.yaml` khi bootstrap.

### Automation

```yaml
automation:
  user_messages_per_conversation: 2    # user message / conversation (mặc định)
  delay_between_messages_seconds: 20
  delay_between_conversations_seconds: 45

sandbox:
  projects:
    - name: fake-api
      conversations_per_day: 4         # conversation / ngày
      user_messages_per_conversation: 3  # ghi đè cho project này
```

- `sessions_per_day` vẫn là alias của `conversations_per_day`.
- Nội dung prompt: `prompts/daily.yaml` — mỗi entry là một conversation; `follow_ups` / `default_follow_ups` cho các user message tiếp theo.

### Agent skills (theo project)

Cài qua [`npx skills`](https://github.com/vercel-labs/agent-skills) (`npx skills --help`):

```yaml
skills:
  default_repo: https://github.com/obra/superpowers
  global_packages:
    - repo: https://github.com/obra/superpowers
      skills: [brainstorming]

sandbox:
  projects:
    - name: fake-api
      skills:
        - systematic-debugging              # shorthand → default_repo
        - repo: https://github.com/obra/superpowers
          names: [writing-plans]
          global: true                       # -g → $HOME/.agents/skills/
```

Cài thủ công:

```bash
SANDBOX=~/ai-counter-sandbox ./scripts/install-sandbox-skills.sh
```

### Lịch & timezone

```yaml
schedule:
  timezone: Asia/Ho_Chi_Minh
  cron: "30 6 * * 1-5"
```

---

## Lưu ý

| # | Nội dung |
|---|----------|
| 1 | Mount sandbox: `-v "$SANDBOX:/home/counter"` — mọi lệnh `exec` dùng `-u counter`. |
| 2 | Sandbox phải writable bởi uid **1000** (`counter`): `./scripts/chown-sandbox.sh "$SANDBOX"`. |
| 3 | **z8l auth:** chỉ trên host (`HOME=$SANDBOX ./bin/z8l auth login`) hoặc copy `supabase-auth.json`. Không login OAuth trong container. |
| 4 | Token z8l: `$SANDBOX/.z8l/cli/supabase-auth.json` — không commit sandbox. |
| 5 | Cursor: truyền `CURSOR_API_KEY` khi `docker run` (cron/headless). |
| 6 | SELinux: volume có thể cần `:z` / `:Z` (xem [README.podman.md](README.podman.md) nếu dùng Podman). |
| 7 | Test nhanh: `conversations_per_day: 1`, `user_messages_per_conversation: 1`. |
| 8 | `HOME is not writable` → `./scripts/chown-sandbox.sh "$SANDBOX"` và kiểm tra quyền mount. |
| 9 | Giờ container lệch host → `./scripts/docker-run.sh` hoặc `-e TZ` + mount `/etc/localtime`; kiểm tra `schedule.timezone`. |

---

## Thiếu `bin/z8l`?

```bash
export Z8L_DOWNLOAD_URL='https://.../z8l_Linux_x86_64.zip?token=...'
./scripts/vendor-z8l.sh
```

---

## Phát triển local (không container)

```bash
export SANDBOX=~/ai-counter-sandbox
HOME="$SANDBOX" uv run ai-counter daily --dry-run
./scripts/integration-test.sh
```
