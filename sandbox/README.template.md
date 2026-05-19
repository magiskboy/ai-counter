# AI-counter sandbox (mount as container HOME)

This directory is **not** part of the git repo. Create it on your host and mount it for user **`counter`**:

```bash
./scripts/chown-sandbox.sh /path/to/this/sandbox

podman run -d \
  --name ai-counter \
  --restart unless-stopped \
  -e CURSOR_API_KEY="your-key" \
  -e CONTEXT7_API_KEY="your-context7-key" \
  -v /path/to/this/sandbox:/home/counter \
  ai-counter:latest
```

## Layout

```
$SANDBOX/                    # → /home/counter (HOME of user `counter`)
├── ai-counter/
│   ├── config.yaml
│   └── logs/
├── projects/
│   ├── fake-api/
│   ├── fake-web/
│   └── fake-lib/
├── .cursor/
│   ├── mcp.json             # context7 MCP (CONTEXT7_API_KEY)
│   └── cli-config.json      # Mcp/WebFetch allowlist for headless
├── .agents/
│   └── skills/              # npx skills add -g (e.g. brainstorming)
├── .z8l/cli/
│   ├── config.toml
│   └── auth.json            # after z8l auth login
├── .config/ai-counter/
│   └── state.json
└── bin/z8l                  # optional (host dev); image has /usr/local/bin/z8l
```

## Bootstrap

From the AI-counter repo (installs skills via `npx skills add ... -g -y -a cursor`):

```bash
SANDBOX=~/my-ai-sandbox ./sandbox/bootstrap.sh
./scripts/chown-sandbox.sh ~/my-ai-sandbox
```

## Skills (non-interactive)

```bash
SANDBOX=~/my-ai-sandbox ./scripts/install-sandbox-skills.sh
# or:
HOME=$SANDBOX npx -y skills add https://github.com/obra/superpowers \
  --skill brainstorming -g -y -a cursor
```

## Auth (one-time, inside sandbox HOME)

```bash
podman exec -u counter -it ai-counter z8l auth login
podman exec -u counter -it ai-counter cursor-agent login   # or CURSOR_API_KEY when running container

# Or on host:
HOME=$SANDBOX z8l auth login
HOME=$SANDBOX z8l auth status
```
