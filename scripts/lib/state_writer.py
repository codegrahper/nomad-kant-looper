#!/usr/bin/env python3
"""state_writer.py — Kant Observability Contract (Phase 1)

phase-events.log 를 단일 소스로 삼아, 각 run state directory 에
Dashboard 용 machine-readable 파일 두 개를 재생성한다.

  run-state.json   현재 상태 스냅샷 (atomic write)
  events.jsonl     이벤트 타임라인 (append-only 뷰, 매번 재생성)

핵심 원칙:
  - phase-events.log 및 기존 flat 상태 파일은 읽기만 한다. 절대 삭제/변경하지 않는다.
  - 완전 idempotent: 같은 입력이면 항상 같은 출력. 매 이벤트마다 전체 재생성해도 안전.
  - 실패해도 Core 를 죽이지 않는다(호출측이 `|| true`). 여기서는 최선을 다하되 예외를 삼킨다.

계약 스키마는 docs/dashboard/STATE-CONTRACT.md 참조.
"""

import datetime
import json
import os
import re
import sys
from pathlib import Path

SCHEMA_VERSION = 1

# phase-events.log 한 줄: "[<UTC ISO8601>] <body>"
_LINE = re.compile(r"^\[([^\]]+)\]\s+(.*)$")


def _now_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_txt(state_dir: Path, name: str):
    """flat 상태 파일 한 줄을 읽는다. 없으면 None."""
    try:
        text = (state_dir / name).read_text(errors="replace").strip()
    except OSError:
        return None
    return text if text != "" else None


def _kv(s: str) -> dict:
    """"role=implement tool=codex model=gpt-5.6-sol" → {role,tool,model}"""
    out = {}
    for tok in s.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def _classify(first: str, rest: str):
    """phase-events.log 의 log_event 라인을 Dashboard 이벤트로 매핑.

    log_event() 를 거치지 않은 raw adapter stderr / gate stdout 라인은
    여기서 None 을 돌려 events.jsonl 에서 제외한다(노이즈 차단).
    """
    d = _kv(rest)
    if first == "RUN_CREATED":
        return {"type": "run_created", "stage": None, "agent": None, "model": None,
                "message": "Run created"}
    if first == "WORKER_STARTED":
        return {"type": "worker_started", "stage": None, "agent": None, "model": None,
                "message": f"worker started mode={d.get('mode')} role={d.get('role')}"}
    if first == "WORKER_ERR":
        return {"type": "worker_error", "stage": None, "agent": None, "model": None,
                "message": f"worker error rc={d.get('rc')} line={d.get('line')}"}
    if first == "QUICK_CALL":
        role = d.get("role")
        return {"type": "agent_started", "stage": role, "agent": d.get("tool"),
                "model": d.get("model"), "message": f"{role} started"}
    if first == "ADAPTER_STARTED":
        return {"type": "adapter_started", "stage": d.get("role"), "agent": d.get("tool"),
                "model": d.get("model"),
                "message": f"adapter started {d.get('tool')}:{d.get('model')}"}
    if first == "QUICK_VERDICT":
        verdict = d.get("verdict")
        return {"type": "agent_verdict", "stage": None, "agent": None, "model": None,
                "message": f"verdict {verdict}", "verdict": verdict}
    if first == "ADAPTER_FAIL":
        return {"type": "agent_failed", "stage": d.get("role"), "agent": d.get("tool"),
                "model": d.get("model"), "message": f"adapter failed mode={d.get('mode')} rc={d.get('rc')}"}
    if first == "FALLBACK_USED":
        return {"type": "fallback_used", "stage": None, "agent": None, "model": None,
                "message": "fallback used"}
    if first == "FALLBACK_ATTEMPT":
        status = d.get("status")
        tool, model = d.get("tool"), d.get("model")
        ev_type = {
            "trying": "fallback_attempt_started",
            "failed": "fallback_attempt_failed",
            "success": "fallback_attempt_succeeded",
        }.get(status, "fallback_attempt")
        msg = f"fallback attempt {tool}:{model} {status}"
        if status == "trying" and d.get("from"):
            msg = f"fallback attempt {tool}:{model} (replacing {d.get('from')})"
        if status == "failed" and d.get("mode"):
            msg += f" ({d.get('mode')})"
        return {"type": ev_type, "stage": d.get("role"), "agent": tool, "model": model,
                "message": msg}
    if first == "FALLBACK_EXHAUSTED":
        return {"type": "fallback_exhausted", "stage": d.get("role"), "agent": None, "model": None,
                "message": f"fallback exhausted, from={d.get('from')} chain={d.get('chain')}"}
    if first == "CHANGED_FILES_MISMATCH:":
        return {"type": "changed_files_mismatch", "stage": "gate", "agent": None,
                "model": None, "message": rest}
    if first == "PARALLEL_REVIEW":
        return {"type": "parallel_review", "stage": "review", "agent": None, "model": None,
                "message": f"parallel review {d.get('chain', '')}".strip()}
    if first == "COMMIT":
        return {"type": "commit_created", "stage": "commit", "agent": None, "model": None,
                "message": f"commit {rest}"}
    if first == "RUN_PASS_NO_COMMIT":
        return {"type": "run_completed", "stage": "done", "agent": None, "model": None,
                "message": "passed (no commit)"}
    if first == "FAIL":
        code = rest.split(":", 1)[0].strip()
        return {"type": "run_failed", "stage": None, "agent": None, "model": None,
                "message": rest, "code": code}
    return None


def _parse_events(state_dir: Path) -> list:
    pe = state_dir / "phase-events.log"
    try:
        lines = pe.read_text(errors="replace").splitlines()
    except OSError:
        return []

    events = []
    seq = 0
    for ln in lines:
        m = _LINE.match(ln)
        if not m:
            continue
        time, body = m.group(1), m.group(2).strip()
        if not body:
            continue
        first = body.split(None, 1)[0]
        rest = body[len(first):].strip()
        ev = _classify(first, rest)
        if ev is None:
            continue
        seq += 1
        ev = {"schema_version": SCHEMA_VERSION, "seq": seq, "time": time, **ev}
        events.append(ev)
    return events


def _derive_status(result, events) -> str:
    if result == "completed" or result == "pass_no_commit":
        return "completed"
    if result == "failed":
        return "failed"
    if result == "cancelled":
        return "cancelled"
    if result is None:
        # worker/adapter 진입도 "실행 중"으로 인정한다. agent_started(QUICK_CALL)만
        # 보면, 워커가 그 전에 죽은 run 이 영영 preparing 으로 남는다(2026-08-04 회귀).
        has_call = any(
            e["type"] in ("agent_started", "adapter_started", "worker_started")
            for e in events
        )
        return "running" if has_call else "preparing"
    return "running"


def _derive_agents(events, status) -> list:
    """QUICK_CALL / QUICK_VERDICT 를 순서대로 매칭해 agent 요약을 만든다.

    verdict/model 상세는 status --json 에 없으므로 phase-events.log 를 소스로 삼는다
    (worktree 의 .kant-looper/*.json 보다 영속적이라 더 안정적).

    fallback이 발생하면 원래 실패한 tool/model이 아니라 실제로 성공(또는 최후 시도)한
    tool/model이 tool/model 필드에 반영되도록 갱신한다 — 폴백으로 넘어갔는데도
    화면/상태에는 원래 실패한 도구가 성공한 것처럼 보이는 오표기를 막기 위함
    (2026-07-24, Dashboard 신뢰성 개선). 시도된 전체 이력은 attempts[]에 남는다.
    """
    agents = []
    cur = None
    for e in events:
        if e["type"] == "agent_started":
            cur = {"role": e.get("stage"), "tool": e.get("agent"),
                   "model": e.get("model"), "status": "running", "verdict": None,
                   "attempts": []}
            agents.append(cur)
        elif e["type"] == "agent_failed" and cur is not None:
            cur["attempts"].append({
                "tool": e.get("agent"), "model": e.get("model"),
                "outcome": "failed", "detail": e.get("message"),
            })
        elif e["type"] == "fallback_attempt_failed" and cur is not None:
            cur["attempts"].append({
                "tool": e.get("agent"), "model": e.get("model"),
                "outcome": "failed", "detail": e.get("message"),
            })
        elif e["type"] == "fallback_attempt_succeeded" and cur is not None:
            cur["attempts"].append({
                "tool": e.get("agent"), "model": e.get("model"),
                "outcome": "succeeded",
            })
            # 실제 실행자로 갱신 — 이 시점부터는 cur["tool"]/["model"]이 진짜 승자를 가리킨다
            if e.get("agent"):
                cur["tool"] = e.get("agent")
            if e.get("model"):
                cur["model"] = e.get("model")
        elif e["type"] == "agent_verdict" and cur is not None:
            v = e.get("verdict")
            cur["verdict"] = v
            cur["status"] = "completed" if v == "PASS" else "failed"
    # run 이 실패로 끝났는데 마지막 agent 가 아직 running 이면(예: fallback 소진 후 FAIL) failed 로 보정
    if status == "failed" and agents and agents[-1]["status"] == "running":
        agents[-1]["status"] = "failed"
    return agents


def _derive_stage(events, status):
    stage = None
    for e in events:
        if e.get("stage"):
            stage = e["stage"]
    if status == "completed":
        stage = "done"
    return stage


def _atomic_write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def build(state_dir: Path) -> None:
    events = _parse_events(state_dir)

    # events.jsonl 재생성
    jsonl = "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in events)
    _atomic_write(state_dir / "events.jsonl", jsonl)

    # run-state.json 조립
    result = _read_txt(state_dir, "result.txt")
    status = _derive_status(result, events)
    agents = _derive_agents(events, status)
    stage = _derive_stage(events, status)

    failure = None
    code = _read_txt(state_dir, "failure-code.txt")
    if code is not None:
        failure = {"code": code, "message": _read_txt(state_dir, "failure-message.txt")}

    started_at = _read_txt(state_dir, "started-at.txt")
    if started_at is None and events:
        started_at = events[0]["time"]

    task = None
    task_md = state_dir / "task.md"
    if task_md.is_file():
        try:
            first_line = task_md.read_text(errors="replace").splitlines()[0]
            task = re.sub(r"^#\s*", "", first_line).strip() or None
        except (OSError, IndexError):
            task = None

    state = {
        "schema_version": SCHEMA_VERSION,
        "run_id": _read_txt(state_dir, "run-id.txt"),
        "repo": _read_txt(state_dir, "repo.txt"),
        "task": task,
        "mode": _read_txt(state_dir, "mode.txt"),
        "status": status,
        "stage": stage,
        "started_at": started_at,
        "updated_at": _now_utc(),
        "branch": _read_txt(state_dir, "branch.txt"),
        "worktree": _read_txt(state_dir, "worktree.txt"),
        "agents": agents,
        "result": result,
        "failure": failure,
        "commit": _read_txt(state_dir, "commit-sha.txt"),
    }
    _atomic_write(state_dir / "run-state.json", json.dumps(state, ensure_ascii=False, indent=2) + "\n")


def main(argv) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: state_writer.py <state_dir>\n")
        return 2
    state_dir = Path(argv[1])
    if not state_dir.is_dir():
        sys.stderr.write(f"state_writer.py: not a directory: {state_dir}\n")
        return 1
    try:
        build(state_dir)
    except Exception as exc:  # 관찰성이 Core 를 죽이지 않는다 — 조용히 실패
        sys.stderr.write(f"state_writer.py: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
