#!/usr/bin/env python3
"""Install agent skills into sandbox HOME via npx skills (non-interactive)."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

import yaml


def main() -> int:
    parser = argparse.ArgumentParser(description="Install agent skills into sandbox HOME")
    parser.add_argument(
        "sandbox",
        nargs="?",
        default=os.environ.get("SANDBOX"),
        help="Sandbox directory (mounted as HOME in container)",
    )
    parser.add_argument(
        "--config",
        default=None,
        help="Path to skills.yaml (default: sandbox/skills.yaml in repo)",
    )
    args = parser.parse_args()

    if not args.sandbox:
        print("Usage: SANDBOX=~/my-ai-sandbox install_sandbox_skills.py", file=sys.stderr)
        return 1

    sandbox = Path(args.sandbox).expanduser().resolve()
    sandbox.mkdir(parents=True, exist_ok=True)

    root = Path(__file__).resolve().parent.parent
    config_path = Path(args.config) if args.config else root / "sandbox" / "skills.yaml"
    if not config_path.is_file():
        print(f"ERROR: missing {config_path}", file=sys.stderr)
        return 1

    with config_path.open(encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    install_opts = cfg.get("install", {})
    global_flag = ["-g"] if install_opts.get("global", True) else []
    yes_flag = ["-y"] if install_opts.get("yes", True) else []
    agent = install_opts.get("agent", "cursor")
    agent_flag = ["-a", agent] if agent else []

    env = os.environ.copy()
    env["HOME"] = str(sandbox)

    npx = "npx"
    try:
        subprocess.run([npx, "--version"], capture_output=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        print("ERROR: npx not found — install Node.js", file=sys.stderr)
        return 1

    (sandbox / ".agents" / "skills").mkdir(parents=True, exist_ok=True)
    print(f"Installing skills into HOME={sandbox}")

    for pkg in cfg.get("packages", []):
        repo = pkg["repo"]
        for skill in pkg.get("skills", []):
            cmd = [
                npx,
                "-y",
                "skills",
                "add",
                repo,
                "--skill",
                skill,
                *global_flag,
                *yes_flag,
                *agent_flag,
            ]
            print(f"\n==> {' '.join(cmd)}")
            subprocess.run(cmd, env=env, check=True)

    print("\nInstalled:")
    subprocess.run(
        [npx, "-y", "skills", "list", "-g"],
        env=env,
        check=False,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
