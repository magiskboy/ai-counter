from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from ai_counter.config import AppConfig, ProjectConfig, SkillPackage, SkillsConfig


@dataclass
class SkillInstallResult:
    installed: list[str]
    skipped: list[str]
    failed: list[str]


def _npx() -> str:
    return shutil.which("npx") or "npx"


def _list_installed(
    home: Path,
    *,
    global_scope: bool,
    project_path: Path | None = None,
) -> set[str]:
    cmd = [_npx(), "-y", "skills", "list", "--json"]
    if global_scope:
        cmd.append("-g")

    env = os.environ.copy()
    env["HOME"] = str(home)
    cwd = project_path if project_path and not global_scope else home

    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return set()

    if proc.returncode != 0:
        return set()

    try:
        items = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return set()

    names: set[str] = set()
    if isinstance(items, list):
        for item in items:
            if isinstance(item, dict) and isinstance(item.get("name"), str):
                names.add(item["name"])
    return names


def _install_one(
    home: Path,
    repo: str,
    skill_name: str,
    *,
    skills_cfg: SkillsConfig,
    global_install: bool,
    project_path: Path | None,
    dry_run: bool,
) -> bool:
    cmd = [
        _npx(),
        "-y",
        "skills",
        "add",
        repo,
        "--skill",
        skill_name,
        "-a",
        skills_cfg.agent,
    ]
    if skills_cfg.yes:
        cmd.append("-y")
    if global_install:
        cmd.append("-g")

    env = os.environ.copy()
    env["HOME"] = str(home)
    cwd = project_path if project_path and not global_install else home

    if dry_run:
        print(f"[dry-run] HOME={home} cwd={cwd} {' '.join(cmd)}")
        return True

    proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        err = ((proc.stderr or "") + (proc.stdout or ""))[:400]
        print(f"skill install failed ({skill_name}): {err}")
        return False
    return True


def install_packages(
    home: Path,
    packages: list[SkillPackage],
    skills_cfg: SkillsConfig,
    *,
    project_path: Path | None = None,
    dry_run: bool = False,
    log_fn=print,
) -> SkillInstallResult:
    """Install skill packages via `npx skills add` (see: npx skills --help)."""
    result = SkillInstallResult(installed=[], skipped=[], failed=[])

    if not packages:
        return result

    if shutil.which("npx") is None and not dry_run:
        log_fn("warning: npx not found — skip skill install (install Node.js)")
        for pkg in packages:
            result.failed.extend(pkg.names)
        return result

    for pkg in packages:
        global_scope = pkg.global_install if pkg.global_install is not None else True
        installed = _list_installed(
            home,
            global_scope=global_scope,
            project_path=project_path if not global_scope else None,
        )
        for name in pkg.names:
            if name in installed:
                result.skipped.append(name)
                log_fn(f"  skill {name}: already installed")
                continue

            log_fn(f"  skill {name}: installing from {pkg.repo}")
            ok = _install_one(
                home,
                pkg.repo,
                name,
                skills_cfg=skills_cfg,
                global_install=global_scope,
                project_path=project_path,
                dry_run=dry_run,
            )
            if ok:
                result.installed.append(name)
            else:
                result.failed.append(name)

    return result


def ensure_global_skills(
    config: AppConfig,
    *,
    dry_run: bool = False,
    log_fn=print,
) -> SkillInstallResult:
    if not config.skills.global_packages:
        return SkillInstallResult([], [], [])

    log_fn(
        f"Ensuring {len(config.skills.global_packages)} global skill package(s) "
        f"in HOME={config.home}"
    )
    (config.home / ".agents" / "skills").mkdir(parents=True, exist_ok=True)
    return install_packages(
        config.home,
        config.skills.global_packages,
        config.skills,
        dry_run=dry_run,
        log_fn=log_fn,
    )


def ensure_project_skills(
    config: AppConfig,
    project: ProjectConfig,
    *,
    dry_run: bool = False,
    log_fn=print,
) -> SkillInstallResult:
    packages = config.project_skill_packages(project)
    if not packages:
        return SkillInstallResult([], [], [])

    proj_path = config.projects_dir / project.name
    log_fn(f"Ensuring skills for {project.name}: {config.project_skill_names(project)}")
    if not dry_run:
        proj_path.mkdir(parents=True, exist_ok=True)

    return install_packages(
        config.home,
        packages,
        config.skills,
        project_path=proj_path,
        dry_run=dry_run,
        log_fn=log_fn,
    )


def skill_context_prefix(config: AppConfig, project: ProjectConfig) -> str:
    """Hint cursor-agent which skills are configured for this project."""
    names = config.project_skill_names(project)
    if not names:
        return ""
    joined = ", ".join(names)
    return (
        f"Configured agent skills for this project: {joined}. "
        "Use the matching skill instructions when a task fits.\n\n"
    )
