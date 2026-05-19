from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

import yaml


@dataclass
class AutomationConfig:
    """Global automation targets (per-project can override)."""

    user_messages_per_conversation: int = 1
    delay_between_messages_seconds: int = 20
    delay_between_conversations_seconds: int | None = None


@dataclass
class ProjectConfig:
    name: str
    conversations_per_day: int = 4
    user_messages_per_conversation: int | None = None

    @property
    def sessions_per_day(self) -> int:
        """Backward-compatible alias."""
        return self.conversations_per_day


@dataclass
class CursorConfig:
    binary: str = "cursor-agent"
    flags: list[str] = field(
        default_factory=lambda: ["-p", "--trust", "-f", "--approve-mcps"]
    )
    timeout_seconds: int = 900
    delay_between_sessions: int = 45


@dataclass
class Z8lConfig:
    binary: str = "/usr/local/bin/z8l"
    sync_provider: str = "cursor"


@dataclass
class PromptsConfig:
    file: str = "/opt/ai-counter/prompts/daily.yaml"
    rotate: str = "daily"


@dataclass
class AppConfig:
    home: Path
    projects_dir: Path
    projects: list[ProjectConfig]
    automation: AutomationConfig
    cursor: CursorConfig
    z8l: Z8lConfig
    prompts: PromptsConfig
    state_path: Path
    logs_dir: Path

    def conversations_per_day(self, project: ProjectConfig) -> int:
        return project.conversations_per_day

    def user_messages_per_conversation(self, project: ProjectConfig) -> int:
        if project.user_messages_per_conversation is not None:
            return project.user_messages_per_conversation
        return self.automation.user_messages_per_conversation

    def delay_between_conversations(self) -> int:
        if self.automation.delay_between_conversations_seconds is not None:
            return self.automation.delay_between_conversations_seconds
        return self.cursor.delay_between_sessions

    @property
    def total_conversations_per_day(self) -> int:
        return sum(p.conversations_per_day for p in self.projects)

    @property
    def total_sessions_per_day(self) -> int:
        """Backward-compatible alias."""
        return self.total_conversations_per_day


def home_dir() -> Path:
    return Path(os.environ.get("HOME", "/home/counter")).resolve()


def config_path(home: Path | None = None) -> Path:
    root = home or home_dir()
    return root / "ai-counter" / "config.yaml"


def _int_or_none(value) -> int | None:
    if value is None:
        return None
    return int(value)


def load_config(home: Path | None = None) -> AppConfig:
    root = home or home_dir()
    path = config_path(root)
    if not path.is_file():
        raise FileNotFoundError(
            f"Missing {path}. Run sandbox/bootstrap.sh and copy config.example.yaml."
        )

    with path.open(encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}

    automation_raw = raw.get("automation", {})
    automation = AutomationConfig(
        user_messages_per_conversation=int(
            automation_raw.get("user_messages_per_conversation", 1)
        ),
        delay_between_messages_seconds=int(
            automation_raw.get("delay_between_messages_seconds", 20)
        ),
        delay_between_conversations_seconds=_int_or_none(
            automation_raw.get("delay_between_conversations_seconds")
        ),
    )

    sandbox = raw.get("sandbox", {})
    projects_dir = root / sandbox.get("projects_dir", "projects")
    projects = []
    for p in sandbox.get("projects", []):
        cpd = p.get("conversations_per_day", p.get("sessions_per_day", 4))
        um = p.get("user_messages_per_conversation")
        projects.append(
            ProjectConfig(
                name=p["name"],
                conversations_per_day=int(cpd),
                user_messages_per_conversation=_int_or_none(um),
            )
        )

    cursor_raw = raw.get("cursor", {})
    cursor = CursorConfig(
        binary=cursor_raw.get("binary", "cursor-agent"),
        flags=list(cursor_raw.get("flags", CursorConfig().flags)),
        timeout_seconds=int(cursor_raw.get("timeout_seconds", 900)),
        delay_between_sessions=int(cursor_raw.get("delay_between_sessions", 45)),
    )

    z8l_raw = raw.get("z8l", {})
    z8l = Z8lConfig(
        binary=z8l_raw.get("binary", "/usr/local/bin/z8l"),
        sync_provider=z8l_raw.get("sync_provider", "cursor"),
    )

    prompts_raw = raw.get("prompts", {})
    prompts = PromptsConfig(
        file=prompts_raw.get("file", "/opt/ai-counter/prompts/daily.yaml"),
        rotate=prompts_raw.get("rotate", "daily"),
    )

    return AppConfig(
        home=root,
        projects_dir=projects_dir,
        projects=projects,
        automation=automation,
        cursor=cursor,
        z8l=z8l,
        prompts=prompts,
        state_path=root / ".config" / "ai-counter" / "state.json",
        logs_dir=root / "ai-counter" / "logs",
    )
