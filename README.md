# AI-counter

Chạy **cursor-agent** tự động trong container, sync/upload session lên **Zen8labs AI Hub** qua **z8l**. Sandbox trên máy bạn mount vào `/home/counter` (user `counter`).

**Cần:** Podman, `bin/z8l` trong repo, `CURSOR_API_KEY`, đã login **z8l** (Zen8labs SSO).

---

## Cài đặt (lần đầu)

```bash
git clone <url-repo>
cd AI-counter

export SANDBOX=~/ai-counter-sandbox
./sandbox/bootstrap.sh
./scripts/chown-sandbox.sh "$SANDBOX"

./docker/build.sh
```

**Đăng nhập z8l** — làm trên **máy host** (không trong container):

```bash
HOME=$SANDBOX ./bin/z8l auth login
# hoặc nếu đã login sẵn trên máy:
cp ~/.z8l/cli/supabase-auth.json "$SANDBOX/.z8l/cli/"
chmod 600 "$SANDBOX/.z8l/cli/supabase-auth.json"
```

**Chạy container:**

```bash
export CURSOR_API_KEY="key_..."          # https://cursor.com/settings
export CONTEXT7_API_KEY="ctx7sk-..."     # tùy chọn, cho MCP context7

podman run -d \
  --name ai-counter \
  --userns=keep-id \
  --restart unless-stopped \
  -e CURSOR_API_KEY \
  -e CONTEXT7_API_KEY \
  -v "$SANDBOX:/home/counter:Z" \
  ai-counter:latest
```

**Kiểm tra:**

```bash
podman logs ai-counter
podman exec -u counter ai-counter z8l auth status
podman exec -u counter ai-counter /opt/ai-counter/docker/run-daily.sh --dry-run
```

---

## Dùng hàng ngày

```bash
# Chạy pipeline ngay (thủ công)
podman exec -u counter ai-counter /opt/ai-counter/docker/run-daily.sh

# Shell trong container
podman exec -u counter -it ai-counter bash

# Upload 1 project
podman exec -u counter -w /home/counter/projects/fake-api ai-counter z8l upload

# Log
tail -f ~/ai-counter-sandbox/ai-counter/logs/daily-*.log
tail -f ~/ai-counter-sandbox/ai-counter/logs/cron.log
```

**Cron tự động:** Thứ 2–6, **06:30 UTC** (user `counter`).

**Sửa mục tiêu automation / delay:** chỉnh `~/ai-counter-sandbox/ai-counter/config.yaml` (không cần rebuild image). Ví dụ:

```yaml
automation:
  user_messages_per_conversation: 2   # mặc định cho mọi project
  delay_between_messages_seconds: 20
  delay_between_conversations_seconds: 45

sandbox:
  projects:
    - name: fake-api
      conversations_per_day: 4        # số conversation mỗi ngày
      user_messages_per_conversation: 3  # ghi đè mặc định cho project này
```

`follow_ups` trong `prompts/daily.yaml` (hoặc `default_follow_ups`) là nội dung các user message tiếp theo trong cùng conversation. `sessions_per_day` vẫn được chấp nhận như alias của `conversations_per_day`.

---

## Lưu ý

| # | Nội dung |
|---|----------|
| 1 | Mount sandbox: **`-v "$SANDBOX:/home/counter"`** — mọi lệnh exec dùng **`-u counter`**. |
| 2 | Podman rootless: luôn thêm **`--userns=keep-id`** khi `podman run`. |
| 3 | **z8l auth:** chỉ login trên host (`HOME=$SANDBOX ./bin/z8l auth login`) hoặc copy `supabase-auth.json`. **Không** `podman exec ... z8l auth login` — OAuth redirect `127.0.0.1` không vào được container. |
| 4 | Token z8l: **`$SANDBOX/.z8l/cli/supabase-auth.json`** — không commit sandbox lên git. |
| 5 | Cursor: truyền **`CURSOR_API_KEY`** khi run container (khuyến nghị cho cron/headless). |
| 6 | Fedora/SELinux: giữ suffix **`:Z`** trên volume mount. |
| 7 | Daily mặc định ~10 conversation; test nhanh: `conversations_per_day: 1` và `user_messages_per_conversation: 1`. |
| 8 | `HOME is not writable` → chạy lại `./scripts/chown-sandbox.sh "$SANDBOX"` + `--userns=keep-id`. |

---

## Thiếu `bin/z8l`?

```bash
export Z8L_DOWNLOAD_URL='https://.../z8l_Linux_x86_64.zip?token=...'
./scripts/vendor-z8l.sh
```
