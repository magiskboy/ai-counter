from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from ai_counter.config import AppConfig


@dataclass
class PreflightResult:
    ok: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def _which(binary: str) -> str | None:
    return shutil.which(binary)


def _run(cmd: list[str], cwd: Path | None = None, timeout: int = 60) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    except FileNotFoundError:
        return 127, f"not found: {cmd[0]}"


def run_preflight(config: AppConfig, *, dry_run: bool = False) -> PreflightResult:
    result = PreflightResult(ok=True)

    if not config.home.is_dir():
        result.errors.append(f"HOME is not a directory: {config.home}")
    elif not os.access(config.home, os.W_OK):
        result.errors.append(f"HOME is not writable: {config.home}")

    if not config.projects_dir.is_dir():
        result.errors.append(f"projects_dir missing: {config.projects_dir}")

    for project in config.projects:
        proj_path = config.projects_dir / project.name
        if not proj_path.is_dir():
            result.errors.append(f"project missing: {proj_path}")

    auth_file = config.home / ".z8l" / "cli" / "auth.json"
    z8l_bin = config.z8l.binary if Path(config.z8l.binary).is_file() else None
    if z8l_bin is None:
        z8l_bin = _which("z8l") or _which(config.z8l.binary)
    if z8l_bin is None and not Path(config.z8l.binary).is_file():
        result.errors.append(f"z8l binary not found: {config.z8l.binary}")
    else:
        z8l_path = z8l_bin if z8l_bin else config.z8l.binary
        code, out = _run([z8l_path, "auth", "status"])
        if code != 0 and not auth_file.is_file():
            msg = "z8l not authenticated. Run: HOME=<sandbox> z8l auth login"
            if dry_run:
                result.warnings.append(msg)
            else:
                result.errors.append(msg)
        elif "not logged in" in out.lower():
            msg = "z8l auth status: not logged in"
            if dry_run:
                result.warnings.append(msg)
            else:
                result.errors.append(msg)
        elif auth_file.is_file():
            pass
        elif "logged in" not in out.lower():
            result.warnings.append(f"z8l auth status unclear: {out[:200]}")

    # cursor-agent uses login state under HOME/.cursor (cursor-agent login in container)

    cursor_bin = _which(config.cursor.binary)
    if cursor_bin is None:
        result.errors.append(f"cursor binary not found: {config.cursor.binary}")
    elif not dry_run:
        code, out = _run([cursor_bin, "--version"], timeout=30)
        if code != 0:
            result.warnings.append(f"cursor-agent --version failed: {out[:200]}")

    prompts_path = Path(config.prompts.file)
    if not prompts_path.is_file():
        result.errors.append(
            f"prompts file missing: {prompts_path} "
            "(expected on mounted sandbox, e.g. ai-counter/prompts/daily.yaml — not in image)"
        )

    if not config.projects:
        result.errors.append("no projects configured")

    if config.total_conversations_per_day < 1:
        result.errors.append("total conversations_per_day must be >= 1")

    if config.automation.user_messages_per_conversation < 1:
        result.errors.append("automation.user_messages_per_conversation must be >= 1")

    for project in config.projects:
        um = config.user_messages_per_conversation(project)
        if um < 1:
            result.errors.append(
                f"user_messages_per_conversation must be >= 1 for {project.name}"
            )
        if project.conversations_per_day < 1:
            result.errors.append(
                f"conversations_per_day must be >= 1 for {project.name}"
            )

    if config.skills.global_packages or any(p.skill_packages for p in config.projects):
        if _which("npx") is None:
            msg = "npx not found — required to install agent skills (Node.js)"
            if dry_run:
                result.warnings.append(msg)
            else:
                result.warnings.append(msg)

    for project in config.projects:
        for pkg in project.skill_packages:
            if not pkg.repo:
                result.errors.append(
                    f"project {project.name}: skill package missing repo "
                    "(set skills.default_repo or repo: per package)"
                )

    result.ok = len(result.errors) == 0
    return result
