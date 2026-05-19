from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path

import yaml

from ai_counter.config import AppConfig, ProjectConfig


@dataclass
class PromptEntry:
    id: str
    prompt: str
    breadth: list[str]


@dataclass
class SessionResult:
    prompt_id: str
    project: str
    ok: bool
    returncode: int
    duration_seconds: float
    error: str = ""


def load_prompts(path: Path) -> list[PromptEntry]:
    with path.open(encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    entries = []
    for item in raw.get("sessions", []):
        entries.append(
            PromptEntry(
                id=str(item["id"]),
                prompt=str(item["prompt"]).strip(),
                breadth=list(item.get("breadth", [])),
            )
        )
    return entries


def _day_index(d: date) -> int:
    return d.toordinal()


def select_prompts(
    all_prompts: list[PromptEntry],
    count: int,
    *,
    rotate: str = "daily",
) -> list[PromptEntry]:
    if not all_prompts:
        return []
    if count >= len(all_prompts):
        return all_prompts[:count]

    if rotate == "daily":
        start = _day_index(date.today()) % len(all_prompts)
    else:
        start = 0

    selected: list[PromptEntry] = []
    for i in range(count):
        selected.append(all_prompts[(start + i) % len(all_prompts)])
    return selected


def load_state(state_path: Path) -> dict:
    if not state_path.is_file():
        return {"active_days": [], "failures": [], "runs": []}
    with state_path.open(encoding="utf-8") as f:
        return json.load(f)


def save_state(state_path: Path, state: dict) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    with state_path.open("w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


def bootstrap_project(config: AppConfig, project: ProjectConfig, *, dry_run: bool) -> bool:
    """Ensure Cursor CLI has a project folder for this directory."""
    z8l = _resolve_z8l(config)
    proj_path = config.projects_dir / project.name
    code, out = _run_cmd([z8l, "list", "cursor"], cwd=proj_path, timeout=60)
    if code == 0 and "no cursor cli project" not in out.lower():
        return True
    if dry_run:
        return True
    return run_cursor_session(
        config,
        proj_path,
        "List the top-level files in this repository in 3 bullet points. Do not modify any files.",
        timeout=300,
    ).ok


def _resolve_z8l(config: AppConfig) -> str:
    p = Path(config.z8l.binary)
    if p.is_file():
        return str(p)
    import shutil

    found = shutil.which("z8l")
    return found or config.z8l.binary


def _run_cmd(
    cmd: list[str],
    *,
    cwd: Path,
    timeout: int,
) -> tuple[int, str]:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, out.strip()


def run_cursor_session(
    config: AppConfig,
    project_path: Path,
    prompt: str,
    *,
    timeout: int | None = None,
) -> SessionResult:
    timeout = timeout or config.cursor.timeout_seconds
    cmd = [
        config.cursor.binary,
        *config.cursor.flags,
        "--workspace",
        str(project_path),
        prompt,
    ]
    start = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=project_path,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        duration = time.monotonic() - start
        ok = proc.returncode == 0
        err = ""
        if not ok:
            err = ((proc.stderr or "") + (proc.stdout or ""))[:500]
        return SessionResult(
            prompt_id="",
            project=project_path.name,
            ok=ok,
            returncode=proc.returncode,
            duration_seconds=duration,
            error=err,
        )
    except subprocess.TimeoutExpired:
        return SessionResult(
            prompt_id="",
            project=project_path.name,
            ok=False,
            returncode=-1,
            duration_seconds=time.monotonic() - start,
            error="timeout",
        )
    except FileNotFoundError as e:
        return SessionResult(
            prompt_id="",
            project=project_path.name,
            ok=False,
            returncode=127,
            duration_seconds=0,
            error=str(e),
        )


def run_project_sessions(
    config: AppConfig,
    project: ProjectConfig,
    prompts: list[PromptEntry],
    *,
    dry_run: bool = False,
    log_fn=print,
) -> list[SessionResult]:
    proj_path = config.projects_dir / project.name
    results: list[SessionResult] = []

    if dry_run:
        for i, entry in enumerate(prompts[: project.sessions_per_day]):
            log_fn(f"[dry-run] {project.name} session {i + 1}: {entry.id}")
            results.append(
                SessionResult(
                    prompt_id=entry.id,
                    project=project.name,
                    ok=True,
                    returncode=0,
                    duration_seconds=0,
                )
            )
        return results

    if not bootstrap_project(config, project, dry_run=False):
        log_fn(f"warning: bootstrap may have failed for {project.name}")

    selected = select_prompts(
        prompts,
        project.sessions_per_day,
        rotate=config.prompts.rotate,
    )

    for i, entry in enumerate(selected):
        log_fn(f"[{project.name}] session {i + 1}/{len(selected)}: {entry.id}")
        result = run_cursor_session(config, proj_path, entry.prompt)
        result.prompt_id = entry.id
        results.append(result)
        if not result.ok:
            log_fn(f"  failed (code {result.returncode}): {result.error[:200]}")
        else:
            log_fn(f"  ok ({result.duration_seconds:.1f}s)")

        if i < len(selected) - 1 and config.cursor.delay_between_sessions > 0:
            time.sleep(config.cursor.delay_between_sessions)

    return results


def sync_and_upload(config: AppConfig, project_path: Path, *, dry_run: bool, log_fn=print) -> bool:
    if dry_run:
        log_fn(f"[dry-run] z8l sync + upload in {project_path}")
        return True

    z8l = _resolve_z8l(config)
    provider = config.z8l.sync_provider

    code, out = _run_cmd(
        [z8l, "sync", provider, "--local-time-zone", "--silent"],
        cwd=project_path,
        timeout=600,
    )
    if code != 0:
        log_fn(f"sync failed ({code}): {out[:300]}")
        return False

    code, out = _run_cmd(
        [z8l, "upload", "--console"],
        cwd=project_path,
        timeout=600,
    )
    if code != 0:
        log_fn(f"upload failed ({code}): {out[:300]}")
        return False

    log_fn(f"sync+upload ok for {project_path.name}")
    return True


def record_run(config: AppConfig, results: list[SessionResult], *, upload_ok: bool) -> None:
    state = load_state(config.state_path)
    today = date.today().isoformat()
    active = list(state.get("active_days", []))
    if today not in active:
        active.append(today)

    runs = list(state.get("runs", []))
    runs.append(
        {
            "date": today,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "sessions_ok": sum(1 for r in results if r.ok),
            "sessions_total": len(results),
            "upload_ok": upload_ok,
        }
    )
    state["active_days"] = active[-90:]
    state["runs"] = runs[-60:]
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    save_state(config.state_path, state)
