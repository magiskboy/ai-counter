from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

from ai_counter.config import load_config
from ai_counter.preflight import run_preflight
from ai_counter.sessions import (
    load_prompts,
    record_run,
    run_project_sessions,
    sync_and_upload,
)


def _log_path(config) -> Path:
    config.logs_dir.mkdir(parents=True, exist_ok=True)
    day = datetime.now(timezone.utc).strftime("%Y%m%d")
    return config.logs_dir / f"daily-{day}.log"


def _make_logger(log_file: Path):
    def log(msg: str) -> None:
        line = f"{datetime.now(timezone.utc).isoformat()} {msg}"
        print(line, flush=True)
        with log_file.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    return log


def run_daily(*, dry_run: bool = False) -> int:
    config = load_config()
    log_file = _log_path(config)
    log = _make_logger(log_file)

    log("=== ai-counter daily start ===")
    log(f"HOME={config.home} dry_run={dry_run}")

    preflight = run_preflight(config, dry_run=dry_run)
    for w in preflight.warnings:
        log(f"warning: {w}")
    if not preflight.ok:
        for e in preflight.errors:
            log(f"error: {e}")
        log("preflight failed")
        return 1
    log("preflight ok")

    prompts = load_prompts(Path(config.prompts.file))
    log(f"loaded {len(prompts)} prompts from {config.prompts.file}")

    all_results = []
    all_upload_ok = True

    for project in config.projects:
        log(f"--- project: {project.name} ({project.sessions_per_day} sessions) ---")
        proj_path = config.projects_dir / project.name
        results = run_project_sessions(
            config,
            project,
            prompts,
            dry_run=dry_run,
            log_fn=log,
        )
        all_results.extend(results)

        upload_ok = sync_and_upload(
            config,
            proj_path,
            dry_run=dry_run,
            log_fn=log,
        )
        if not upload_ok:
            all_upload_ok = False

    if not dry_run:
        record_run(config, all_results, upload_ok=all_upload_ok)

    ok_count = sum(1 for r in all_results if r.ok)
    log(
        f"=== done: {ok_count}/{len(all_results)} sessions ok, upload_ok={all_upload_ok} ==="
    )
    return 0 if ok_count == len(all_results) and all_upload_ok else 2


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="AI-counter daily orchestrator")
    parser.add_argument(
        "command",
        nargs="?",
        default="daily",
        choices=["daily"],
        help="command to run",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate config and print planned actions without calling agents",
    )
    args = parser.parse_args(argv)

    if args.command == "daily":
        code = run_daily(dry_run=args.dry_run)
        sys.exit(code)


if __name__ == "__main__":
    main()
