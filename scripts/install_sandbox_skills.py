#!/usr/bin/env python3
"""Install agent skills into sandbox HOME via npx skills (non-interactive)."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import yaml

from ai_counter.config import SkillPackage, SkillsConfig
from ai_counter.skills import ensure_global_skills, install_packages


def _load_legacy_skills_yaml(path: Path) -> tuple[SkillsConfig, list[SkillPackage]]:
    with path.open(encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    install_opts = cfg.get("install", {})
    skills_cfg = SkillsConfig(
        agent=str(install_opts.get("agent", "cursor")),
        yes=bool(install_opts.get("yes", True)),
    )
    default_global = bool(install_opts.get("global", True))

    packages: list[SkillPackage] = []
    for pkg in cfg.get("packages", []):
        repo = pkg["repo"]
        for skill in pkg.get("skills", []):
            packages.append(
                SkillPackage(
                    repo=repo,
                    names=[str(skill)],
                    global_install=default_global,
                )
            )
    return skills_cfg, packages


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
        help="Path to skills.yaml (legacy) or ai-counter/config.yaml",
    )
    args = parser.parse_args()

    if not args.sandbox:
        print("Usage: SANDBOX=~/my-ai-sandbox install_sandbox_skills.py", file=sys.stderr)
        return 1

    sandbox = Path(args.sandbox).expanduser().resolve()
    sandbox.mkdir(parents=True, exist_ok=True)

    root = Path(__file__).resolve().parent.parent
    config_path = Path(args.config) if args.config else None

    if config_path is None:
        sandbox_config = sandbox / "ai-counter" / "config.yaml"
        legacy = root / "sandbox" / "skills.yaml"
        if sandbox_config.is_file():
            config_path = sandbox_config
        else:
            config_path = legacy

    if not config_path.is_file():
        print(f"ERROR: missing {config_path}", file=sys.stderr)
        return 1

    if config_path.name == "config.yaml":
        from ai_counter.config import load_config

        app = load_config(sandbox)
        skills_cfg = app.skills
        packages = app.skills.global_packages
        for project in app.projects:
            packages = [*packages, *project.skill_packages]
        # Deduplicate by (repo, name, global)
        seen: set[tuple[str, str, bool | None]] = set()
        unique: list[SkillPackage] = []
        for pkg in packages:
            key = (pkg.repo, tuple(pkg.names), pkg.global_install)
            if key in seen:
                continue
            seen.add(key)
            unique.append(pkg)
        packages = unique
    else:
        skills_cfg, packages = _load_legacy_skills_yaml(config_path)

    if not packages:
        print(f"No skill packages in {config_path}")
        return 0

    print(f"Installing skills into HOME={sandbox} (from {config_path})")
    (sandbox / ".agents" / "skills").mkdir(parents=True, exist_ok=True)

    result = install_packages(
        sandbox,
        packages,
        skills_cfg,
        dry_run=False,
        log_fn=print,
    )

    if result.failed:
        print(f"\nFailed: {result.failed}", file=sys.stderr)
        return 1

    print(f"\nInstalled: {result.installed}; skipped: {result.skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
