from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path

import yaml

from ai_counter.config import AppConfig, ProjectConfig
from ai_counter.skills import skill_context_prefix

DEFAULT_FOLLOW_UPS = [
    (
        "Continue: pick one idea from your last reply and go one level deeper. "
        "Do not modify files unless necessary."
    ),
    "What are the top 3 risks or gaps with this approach? Keep it concise.",
    "Summarize your findings in 5 bullets and suggest one concrete next step.",
    "Challenge one assumption from your previous answer and propose an alternative.",
]


@dataclass
class PromptEntry:
    id: str
    prompt: str
    breadth: list[str]
    follow_ups: list[str]


@dataclass
class PromptsBundle:
    sessions: list[PromptEntry]
    default_follow_ups: list[str]


@dataclass
class SessionResult:
    prompt_id: str
    project: str
    ok: bool
    returncode: int
    duration_seconds: float
    user_messages: int = 1
    error: str = ""


def load_prompts(path: Path) -> PromptsBundle:
    with path.open(encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}

    default_follow_ups = [
        str(line).strip()
        for line in raw.get("default_follow_ups", DEFAULT_FOLLOW_UPS)
        if str(line).strip()
    ]
    if not default_follow_ups:
        default_follow_ups = list(DEFAULT_FOLLOW_UPS)

    entries = []
    for item in raw.get("sessions", []):
        follow_ups = [
            str(line).strip()
            for line in item.get("follow_ups", [])
            if str(line).strip()
        ]
        entries.append(
            PromptEntry(
                id=str(item["id"]),
                prompt=str(item["prompt"]).strip(),
                breadth=list(item.get("breadth", [])),
                follow_ups=follow_ups,
            )
        )
    return PromptsBundle(sessions=entries, default_follow_ups=default_follow_ups)


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


def build_user_messages(
    entry: PromptEntry,
    *,
    count: int,
    default_follow_ups: list[str],
) -> list[str]:
    """First message is entry.prompt; remaining slots use follow_ups then defaults."""
    if count < 1:
        return []
    messages = [entry.prompt]
    if count == 1:
        return messages

    pool = list(entry.follow_ups) + list(default_follow_ups)
    if not pool:
        pool = list(DEFAULT_FOLLOW_UPS)

    idx = 0
    while len(messages) < count:
        messages.append(pool[idx % len(pool)])
        idx += 1
    return messages


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
    result, _ = run_cursor_message_with_session(
        config,
        proj_path,
        "List the top-level files in this repository in 3 bullet points. Do not modify any files.",
        timeout=300,
    )
    return result.ok


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


def _parse_session_id(stdout: str) -> str | None:
    text = stdout.strip()
    if not text:
        return None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return None
    if isinstance(payload, dict):
        sid = payload.get("session_id")
        if isinstance(sid, str) and sid:
            return sid
    return None


def run_cursor_message(
    config: AppConfig,
    project_path: Path,
    prompt: str,
    *,
    session_id: str | None = None,
    timeout: int | None = None,
) -> SessionResult:
    timeout = timeout or config.cursor.timeout_seconds
    cmd = [
        config.cursor.binary,
        *config.cursor.flags,
        "--output-format",
        "json",
        "--workspace",
        str(project_path),
    ]
    if session_id:
        cmd.extend(["--resume", session_id])
    cmd.append(prompt)

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


def run_cursor_message_with_session(
    config: AppConfig,
    project_path: Path,
    prompt: str,
    *,
    session_id: str | None = None,
    timeout: int | None = None,
) -> tuple[SessionResult, str | None]:
    """Like run_cursor_message but also returns session_id from JSON stdout."""
    timeout = timeout or config.cursor.timeout_seconds
    cmd = [
        config.cursor.binary,
        *config.cursor.flags,
        "--output-format",
        "json",
        "--workspace",
        str(project_path),
    ]
    if session_id:
        cmd.extend(["--resume", session_id])
    cmd.append(prompt)

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
        stdout = proc.stdout or ""
        ok = proc.returncode == 0
        err = ""
        if not ok:
            err = ((proc.stderr or "") + stdout)[:500]
        new_session_id = _parse_session_id(stdout) or session_id
        result = SessionResult(
            prompt_id="",
            project=project_path.name,
            ok=ok,
            returncode=proc.returncode,
            duration_seconds=duration,
            error=err,
        )
        return result, new_session_id
    except subprocess.TimeoutExpired:
        return (
            SessionResult(
                prompt_id="",
                project=project_path.name,
                ok=False,
                returncode=-1,
                duration_seconds=time.monotonic() - start,
                error="timeout",
            ),
            session_id,
        )
    except FileNotFoundError as e:
        return (
            SessionResult(
                prompt_id="",
                project=project_path.name,
                ok=False,
                returncode=127,
                duration_seconds=0,
                error=str(e),
            ),
            session_id,
        )


def run_conversation(
    config: AppConfig,
    project_path: Path,
    messages: list[str],
    *,
    log_fn=print,
) -> SessionResult:
    """Run one conversation: multiple user messages in the same session."""
    if not messages:
        return SessionResult(
            prompt_id="",
            project=project_path.name,
            ok=False,
            returncode=1,
            duration_seconds=0,
            user_messages=0,
            error="no messages",
        )

    session_id: str | None = None
    total_duration = 0.0
    last_code = 0

    for i, message in enumerate(messages):
        label = f"msg {i + 1}/{len(messages)}"
        log_fn(f"    {label}")
        result, session_id = run_cursor_message_with_session(
            config,
            project_path,
            message,
            session_id=session_id,
        )
        total_duration += result.duration_seconds
        last_code = result.returncode

        if not result.ok:
            return SessionResult(
                prompt_id="",
                project=project_path.name,
                ok=False,
                returncode=result.returncode,
                duration_seconds=total_duration,
                user_messages=i + 1,
                error=result.error,
            )

        if i < len(messages) - 1:
            delay = config.automation.delay_between_messages_seconds
            if delay > 0:
                time.sleep(delay)

    return SessionResult(
        prompt_id="",
        project=project_path.name,
        ok=True,
        returncode=last_code,
        duration_seconds=total_duration,
        user_messages=len(messages),
    )


def run_project_sessions(
    config: AppConfig,
    project: ProjectConfig,
    prompts: PromptsBundle,
    *,
    dry_run: bool = False,
    log_fn=print,
) -> list[SessionResult]:
    proj_path = config.projects_dir / project.name
    results: list[SessionResult] = []
    conversations = config.conversations_per_day(project)
    user_messages = config.user_messages_per_conversation(project)
    skill_prefix = skill_context_prefix(config, project)

    def _with_skill_context(msgs: list[str]) -> list[str]:
        if not skill_prefix or not msgs:
            return msgs
        return [skill_prefix + msgs[0], *msgs[1:]]

    if dry_run:
        selected = select_prompts(
            prompts.sessions,
            conversations,
            rotate=config.prompts.rotate,
        )
        for i, entry in enumerate(selected):
            msgs = _with_skill_context(
                build_user_messages(
                    entry,
                    count=user_messages,
                    default_follow_ups=prompts.default_follow_ups,
                )
            )
            log_fn(
                f"[dry-run] {project.name} conversation {i + 1}/{conversations}: "
                f"{entry.id} ({len(msgs)} user messages)"
            )
            for j, msg in enumerate(msgs):
                preview = msg.replace("\n", " ")[:80]
                log_fn(f"  [dry-run]   message {j + 1}: {preview}...")
            results.append(
                SessionResult(
                    prompt_id=entry.id,
                    project=project.name,
                    ok=True,
                    returncode=0,
                    duration_seconds=0,
                    user_messages=len(msgs),
                )
            )
        return results

    if not bootstrap_project(config, project, dry_run=False):
        log_fn(f"warning: bootstrap may have failed for {project.name}")

    selected = select_prompts(
        prompts.sessions,
        conversations,
        rotate=config.prompts.rotate,
    )

    delay_conv = config.delay_between_conversations()

    for i, entry in enumerate(selected):
        msgs = _with_skill_context(
            build_user_messages(
                entry,
                count=user_messages,
                default_follow_ups=prompts.default_follow_ups,
            )
        )
        log_fn(
            f"[{project.name}] conversation {i + 1}/{len(selected)}: "
            f"{entry.id} ({len(msgs)} user messages)"
        )
        result = run_conversation(config, proj_path, msgs, log_fn=log_fn)
        result.prompt_id = entry.id
        results.append(result)
        if not result.ok:
            log_fn(f"  failed (code {result.returncode}): {result.error[:200]}")
        else:
            log_fn(f"  ok ({result.duration_seconds:.1f}s, {result.user_messages} messages)")

        if i < len(selected) - 1 and delay_conv > 0:
            time.sleep(delay_conv)

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
            "user_messages_total": sum(r.user_messages for r in results),
            "upload_ok": upload_ok,
        }
    )
    state["active_days"] = active[-90:]
    state["runs"] = runs[-60:]
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    save_state(config.state_path, state)
