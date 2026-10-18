"""Export complete Escrow games and join candidate decisions to resolved turn events."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
OUTPUT = Path(tempfile.mkdtemp(prefix="escrow-source-export-"))
revision = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
).strip()
for variant, turns in (("standard", 16), ("sprint", 8)):
    output = OUTPUT / variant
    subprocess.run(
        [str(EXPORTER), str(output), "10", "1", variant],
        cwd=ROOT,
        check=True,
        timeout=600,
    )
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision and len(manifest["runs"]) == 10
    assert (
        not (output / "train.jsonl").exists()
        and not (output / "validation.jsonl").exists()
    )
    episodes, decisions, executions = {}, {}, {}
    for filename in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / filename).stat().st_mode & 0o777 == 0o600
    for line in (output / "trajectories.jsonl").read_text().splitlines():
        row = json.loads(line)
        assert row["source_revision"] == revision
        episode = row["episode_id"]
        if row["event_type"] == "episode":
            episodes[episode] = row
            continue
        decisions.setdefault(episode, []).append(row)
        assert row["visibility"] == "private"
        (attempt,) = row["attempts"]
        assert attempt["origin"] == "teacher" and attempt["request"] is None
        assert (
            attempt["platform_call_id"] is None and attempt["behavior_logprobs"] is None
        )
        assert attempt["parsed_action"] == json.loads(attempt["response"])
        if row["action_status"] == "accepted":
            assert (
                row["selected_attempt_id"] == attempt["attempt_id"]
                and attempt["accepted"]
            )
            assert row["executed_action"] == attempt["parsed_action"]
        else:
            assert row["action_status"] == "fallback" and not attempt["accepted"]
            assert row["selected_attempt_id"] is None and row["prompt"] is None
            assert row["fallback_origin"] == "engine-normalized-submission"
        view = row["observation"]
        assert all(
            "notes" not in other and "notes" not in other["state"]
            for other in view["public_floor"]
        )
        metadata = view["prompt_template"]
        assert (
            metadata["bank"] == "escrow-rules-v1" and metadata["variant"] == "canonical"
        )
        for message in attempt["prompt"]:
            assert (
                metadata[message["role"] + "_sha256"].lower()
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
    for line in (output / "execution.jsonl").read_text().splitlines():
        row = json.loads(line)
        executions.setdefault(row["episode_id"], []).append(row)
        assert row["visibility"] == "private" and row["source_revision"] == revision
    assert len(episodes) == 10 and set(episodes) == set(decisions) == set(executions)
    for episode, outcome in episodes.items():
        rows, applied = decisions[episode], executions[episode]
        assert (
            outcome["status"] == "completed"
            and outcome["outcome"]["reason"] == "complete"
        )
        assert (
            outcome["outcome"]["turns"] == turns
            and len(rows) == len(applied) == turns * 4
        )
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
        public, interval = None, None
        for index, (row, execution) in enumerate(zip(rows, applied, strict=True)):
            seat = index % 4
            assert row["decision_id"] == execution["decision_id"] == str(index)
            assert row["seat"] == str(seat) and execution["seat"] == seat
            view, action = row["observation"], row["executed_action"]
            snapshot = (view["public_floor"], view["board"], view["recent"])
            if seat == 0:
                if interval is not None:
                    assert execution["event_start"] == interval[1]
                public = snapshot
                interval = (execution["event_start"], execution["event_end"])
            assert snapshot == public and interval == (
                execution["event_start"],
                execution["event_end"],
            )
            assert interval[1] - interval[0] == len(execution["events"])
            assert execution["turn"] == view["turn"] == index // 4
            events = [
                event for event in execution["events"] if event.get("seat") == seat
            ]
            (move,) = [event for event in events if event["kind"] == "move"]
            assert move["scripted"]
            assert action == execution["resolved_action"]
            assert action["sign"] == [
                event["id"]
                for event in events
                if event["kind"] == "sign" and event["ok"]
            ]
            assert action["give"] == [
                {"to": event["to"], "n": event["n"], "good": event["good"]}
                for event in events
                if event["kind"] == "give" and event["ok"]
            ]
            offers = [event["dsl"] for event in events if event["kind"] == "offer"]
            assert action["offer"] == (offers[0] if offers else "")
            assert action["say"] == move.get("say", "")
            assert action["notes"] == execution["stored_notes"] == move.get("text", "")
        for seat in range(4):
            assert (
                outcome["participant_outcomes"][str(seat)]["score"]
                == outcome["outcome"]["scores"][seat]
            )
    assert {row["seed_family"] for row in episodes.values()} == {
        f"escrow-{seed}" for seed in range(1, 11)
    }
    print(
        variant,
        "10 complete exports; private observations, hashes, resolved actions and outcomes PASS",
        flush=True,
    )
print("Evidence:", OUTPUT)
