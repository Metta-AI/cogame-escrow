"""Run a complete native Escrow game with isolated native-batch loopback inference."""

import argparse
import base64
import http.server
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from pathlib import Path

from websockets.sync.client import connect


def first_object(text):
    start = text.find("{")
    if start < 0:
        raise ValueError("no native object")
    depth, quoted, escaped = 0, False, False
    for index in range(start, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise ValueError("unclosed native object")


def strict_object(text):
    def pairs(entries):
        result = {}
        for key, value in entries:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def bounded(value, depth=0):
        if depth > 32 or isinstance(value, float) and not math.isfinite(value):
            raise ValueError("nonfinite/deep JSON")
        if isinstance(value, dict):
            for item in value.values():
                bounded(item, depth + 1)
        if isinstance(value, list):
            for item in value:
                bounded(item, depth + 1)

    value = json.loads(first_object(text), object_pairs_hook=pairs)
    bounded(value)
    return value


def supplied_equal(raw, actual):
    if type(raw) is not type(actual):
        return False
    if isinstance(raw, dict):
        return all(
            key in actual and supplied_equal(value, actual[key])
            for key, value in raw.items()
        )
    if isinstance(raw, list):
        return len(raw) == len(actual) and all(
            supplied_equal(a, b) for a, b in zip(raw, actual)
        )
    return raw == actual


def fixture_reply(mode, request, slot):
    """Declared local wire fixtures; never provider models or teacher targets."""
    user = request["messages"][0]["content"]
    matched = re.search(r"^Turn (\d+) of (\d+)", user)
    assert matched is not None
    turn, turns = map(int, matched.groups())
    combined = mode == "fidelity"
    if combined:
        mode = "normalization" if turn < 8 else "grammar"
    floor = user.split("THE FLOOR:\n", 1)[1].split("THE ESCROW BOARD:", 1)[0]
    aliases = [
        line.split("|")[0].strip()
        for line in floor.splitlines()
        if "|" in line and not line.startswith("cog")
    ]
    assert len(aliases) == 4
    other = (slot + 1) % 4
    label, text, status, huge_body, huge_header, usage = (
        "normal",
        "{}",
        200,
        False,
        False,
        None,
    )
    retry = "Your previous reply was invalid:" in user
    if mode == "rich" or mode == "normalization" and turn < 4 and not combined:
        action = {
            "give": [
                {
                    "to": aliases[other] if (turn + slot) % 2 else other,
                    "n": 1,
                    "good": "ORE",
                }
            ],
            "say": f"public-slot-{slot}-turn-{turn}",
        }
        if turn == 0:
            action["notes"] = f"private-note-canary-slot-{slot}"
        elif turn == 1:
            action["notes"] = (
                ""  # A genuine empty command preserves the earlier private note.
            )
        if slot != 3 and turn < turns - 1:
            action["offer"] = (
                f"OFFER {aliases[3]}\nLOCK 1 HEARTS\nASK NOTHING\nDUE {turn + 1}\nIF ALWAYS\nTHEN SWAP\nELSE KEEP"
            )
        if slot == 3:
            signable = user.split("SIGNABLE NOW", 1)[1].split("YOUR OPEN OFFERS", 1)[0]
            action["sign"] = re.findall(r"^\s+(C\d+) from", signable, re.MULTILINE)[:2]
        label, text = "native-rich", json.dumps(action)
    elif mode == "normalization":
        give = {"to": aliases[other], "n": 1, "good": "ORE"}
        cases = [
            ("native-fence-default", "```json\n{}\n```"),
            ("native-first-object", '{} trailing prose {"ignored":1}'),
            ("numeric-string", json.dumps({"give": [give | {"n": "1"}]})),
            ("numeric-float", json.dumps({"give": [give | {"n": 1.0}]})),
            ("good-case", json.dumps({"give": [give | {"good": "ore"}]})),
            (
                "alias-trim",
                json.dumps({"give": [give | {"to": " " + aliases[other] + " "}]}),
            ),
            (
                "alias-case",
                json.dumps({"give": [give | {"to": aliases[other].lower()}]}),
            ),
            (
                "give-cap",
                json.dumps({"give": [{"to": other, "n": 1, "good": "HEARTS"}] * 3}),
            ),
            ("notes-trim", '{"notes":" note "}'),
            ("notes-cap", json.dumps({"notes": "n" * 601})),
            ("say-newline", '{"say":"a\\nb"}'),
            ("say-cap", json.dumps({"say": "s" * 161})),
            ("offer-trim", '{"offer":"  "}'),
            ("ignored-field", '{"ignored":1}'),
            ("null-field", '{"notes":null}'),
            ("boolean-field", '{"notes":false}'),
            ("duplicate-key", '{"notes":"","notes":""}'),
            ("nonfinite-field", '{"ignored":1e999}'),
        ]
        label, text = cases[(turn * 4 + slot) % len(cases)]
        if retry:
            label, text = "valid-native-retry", "{}"
    elif mode == "grammar":
        cases = [
            ("trailing-object", '{"notes":"",}'),
            ("trailing-array", '{"sign":["C1",]}'),
            ("comment", '{"notes":""/*local*/}'),
            ("leading-zero", '{"ignored":01}'),
            ("plus-number", '{"ignored":+1}'),
            ("invalid-escape", '{"notes":"\\q"}'),
            ("depth-bound", '{"ignored":' + "[" * 34 + "0" + "]" * 34 + "}"),
            ("non-json-whitespace", '{\v"notes":""}'),
            ("native-fence-default", "```json\n{}\n```"),
            ("native-first-object", '{} trailing {"ignored":1}'),
            ("negative-usage", "{}"),
            ("zero-usage", "{}"),
            ("missing-usage-model", "{}"),
        ]
        label, text = cases[(turn * 4 + slot) % len(cases)]
        if retry:
            label, text = "valid-native-retry", "{}"
        if label == "negative-usage":
            usage = {"input_tokens": -3, "output_tokens": -5}
        elif label == "zero-usage":
            usage = {"input_tokens": 0, "output_tokens": 0}
    elif mode == "retry":
        label, text = (
            ("valid-native-retry", "{}")
            if retry
            else ("invalid-first", "no local object")
        )
    elif mode == "errors":
        if turn == 0:
            if slot == 0:
                label, text = "invalid-exhausted", "no local object"
            elif slot == 1:
                label, status = "http429", 429
            elif slot == 2:
                label, huge_header = "overbound-header", True
            else:
                label, huge_body = "overbound-body", True
        elif turn == 1 and slot == 0:
            label, status = "http401", 401
    return {
        "turn": turn,
        "label": label,
        "text": text,
        "status": status,
        "huge_body": huge_body,
        "huge_header": huge_header,
        "usage": usage,
    }


def check_capture(output, calls, mode):
    rows = [
        json.loads(line)
        for line in (output / "trajectory.jsonl").read_text().splitlines()
    ]
    by_id = {call["call_id"]: call for call in calls}
    seen = set()
    statuses = {"accepted": 0, "rejected": 0, "fallback": 0, "missing": 0}
    for row in rows:
        if row["event_type"] != "decision":
            continue
        statuses[row["action_status"]] += 1
        execution = row["observation"]["native_execution"]
        actor = int(row["seat"])
        moves = [
            event
            for event in execution["events"]
            if event["kind"] == "move" and event["seat"] == actor
        ]
        assert len(moves) == 1
        assert execution["typed_action_projection"] == row["executed_action"]
        if mode in {"rich", "normalization", "fidelity"}:
            for other in range(4):
                if other != actor:
                    assert f"private-note-canary-slot-{other}" not in json.dumps(
                        row["observation"]
                    )
                    assert f"private-note-canary-slot-{other}" not in json.dumps(
                        row["executed_action"]
                    )
        for index, attempt in enumerate(row["attempts"]):
            wire = row["observation"]["native_requests"][index]
            cid = attempt["platform_call_id"]
            if cid is None:
                options = [
                    call
                    for call in calls
                    if call["call_id"] not in seen
                    and call["slot"] == actor
                    and call["request_body"] == wire["raw_body"]
                ]
                assert len(options) == 1 and options[0].get("huge_header")
                call = options[0]
                cid = call["call_id"]
            else:
                call = by_id[cid]
            seen.add(cid)
            assert call["slot"] == actor
            assert attempt["request"] == json.loads(call["request_body"])
            assert wire["raw_body"] == call["request_body"]
            assert base64.b64decode(wire["body_b64"]).decode() == call["request_body"]
            assert set(wire["headers"]) <= {
                "content-type",
                "anthropic-version",
                "X-Coworld-Player-Slot",
            }
            assert attempt["response_complete"] and attempt["response_reader_joined"]
            assert attempt["http_status"] == call.get("status", 200)
            if len(call["response_body"].encode()) > 65536:
                assert (
                    attempt["raw_response"] is None
                    and attempt["response_body_b64"] is None
                )
                assert row["observation"]["capture_errors"]
            else:
                assert attempt["raw_response"] == call["response_body"]
                assert (
                    base64.b64decode(attempt["response_body_b64"]).decode()
                    == call["response_body"]
                )
            if call.get("huge_header"):
                assert (
                    attempt["response_headers"] is None
                    and row["observation"]["capture_errors"]
                )
            else:
                assert {k.lower(): v for k, v in attempt["response_headers"].items()}[
                    "x-softmax-llm-call-id"
                ] == cid
            assert attempt["latency_ms"] is None and wire["batch_elapsed_ms"] >= 0
            assert attempt["decoder"] == {"max_tokens": 1100}
            if attempt["accepted"]:
                assert row["selected_attempt_id"] == attempt["attempt_id"]
                assert attempt["parsed_action"] == row["executed_action"]
                assert supplied_equal(
                    strict_object(attempt["response"]), row["executed_action"]
                )
                assert (
                    attempt["rejection_reason"] is None
                    and 200 <= attempt["http_status"] < 300
                )
            if call.get("fixture_case") == "negative-usage":
                assert (
                    attempt["input_tokens"] is None and attempt["output_tokens"] is None
                )
            if call.get("fixture_case") == "zero-usage":
                assert attempt["input_tokens"] == 0 and attempt["output_tokens"] == 0
            if call.get("fixture_case") == "missing-usage-model":
                assert (
                    attempt["input_tokens"] is None and attempt["output_tokens"] is None
                )
        if row["action_status"] != "accepted":
            assert row["selected_attempt_id"] is None
    assert seen == set(by_id)
    if mode in {"normal", "rich", "retry"}:
        assert statuses["accepted"] == len(
            [r for r in rows if r["event_type"] == "decision"]
        )
    if mode in {"normalization", "grammar", "fidelity"}:
        assert statuses["accepted"] and statuses["rejected"]
    if mode in {"rich", "normalization"}:
        rejected_resolutions = [
            event
            for row in rows
            if row["event_type"] == "decision" and row["seat"] == "0"
            for event in row["observation"]["native_execution"]["events"]
            if event["kind"] == "reject"
        ]
        assert rejected_resolutions, "missing native priority/capacity collision"
        assert all(
            row["action_status"] == "accepted"
            for row in rows
            if row["event_type"] == "decision"
            and int(row["decision_id"].split("-")[0]) <= 4
        )
    if mode == "errors":
        assert statuses["fallback"] and rows[-1]["status"] == "failed"
        assert "private capture publication failed" in (output / "game.log").read_text()
    else:
        assert rows[-1]["status"] == "completed"
    return statuses


def main():
    os.umask(0o077)
    allowed = {"PATH", "HOME", "TMPDIR", "LANG", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"}
    if not set(os.environ) <= allowed:
        # Re-exec before launching any native child so parent and children hold no provider keys/routes.
        os.execve(
            sys.executable,
            [sys.executable, *sys.argv],
            {k: v for k, v in os.environ.items() if k in allowed},
        )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", choices=["standard", "sprint"], default="standard")
    parser.add_argument("--seed", type=int, default=15)
    parser.add_argument("--no-capture", action="store_true")
    parser.add_argument(
        "--mode",
        choices=[
            "normal",
            "rich",
            "normalization",
            "grammar",
            "fidelity",
            "retry",
            "errors",
            "collision",
        ],
        default="normal",
    )
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads(Path("coworld_manifest_template.json").read_text())
    config = next(
        v["game_config"] for v in manifest["variants"] if v["id"] == args.variant
    ).copy()
    config.update(seed=args.seed, tokens=[f"local-token-{i}" for i in range(4)])
    (output / "config.json").write_text(json.dumps(config))
    calls, errors = [], []

    class Sentinel(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_PUT(self):
            assert self.path == "/private-trajectory" and args.mode == "errors"
            body = self.rfile.read(int(self.headers["Content-Length"]))
            (output / "trajectory.jsonl").write_bytes(body)
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            if self.path == "/private-trajectory":
                return self.do_PUT()
            try:
                assert self.path == "/v1/messages"
                length = int(self.headers["Content-Length"])
                assert 0 < length <= 65536 and len(calls) < 128
                body = self.rfile.read(length)
                request = json.loads(body)
                assert request["model"] == "local/escrow-capture-sentinel"
                assert request["max_tokens"] == 1100
                slot = int(self.headers["X-Coworld-Player-Slot"])
                assert 0 <= slot < 4
                assert (
                    f"local-operator-canary-{slot}" in request["messages"][0]["content"]
                )
                call = str(uuid.uuid4())
                chosen = fixture_reply(args.mode, request, slot)
                response: dict[str, object] = {
                    "id": "local-message-" + call,
                    "model": "local/escrow-capture-sentinel",
                    "content": [{"type": "text", "text": chosen["text"]}],
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                }
                if chosen["usage"] is not None:
                    response["usage"] = chosen["usage"]
                if chosen["label"] == "missing-usage-model":
                    del response["usage"]
                    del response["model"]
                if chosen["status"] != 200:
                    response = {"error": {"message": chosen["label"]}}
                if chosen["huge_body"]:
                    response["padding"] = "x" * 70000
                encoded = json.dumps(response).encode()
                calls.append(
                    {
                        "call_id": call,
                        "slot": slot,
                        "turn": chosen["turn"],
                        "fixture_case": chosen["label"],
                        "status": chosen["status"],
                        "huge_header": chosen["huge_header"],
                        "request_started": time.monotonic(),
                        "request_body": body.decode(),
                        "response_body": encoded.decode(),
                    }
                )
                calls[-1]["elapsed_seconds"] = time.monotonic() - started
                with (output / "loopback-http.jsonl").open("a") as archive:
                    archive.write(json.dumps(calls[-1]) + "\n")
                # Retain actual dispatch timing without imposing a protocol barrier.
                time.sleep(0.4)
                self.send_response(chosen["status"])
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.send_header("X-Softmax-Llm-Call-Id", call)
                self.send_header("request-id", "local-request-" + call)
                if chosen["huge_header"]:
                    self.send_header("local-overbound-header", "x" * 17000)
                self.end_headers()
                self.wfile.write(encoded)
                next(c for c in calls if c["call_id"] == call)["response_finished"] = (
                    time.monotonic()
                )
            except Exception as error:
                errors.append(repr(error))
                raise

    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    clean = {
        k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ
    }
    with socket.socket() as available:
        available.bind(("127.0.0.1", 0))
        port = available.getsockname()[1]
    env = clean | {
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": "local-escrow-full-native-fixture",
        "COWORLD_GAME_VERSION": "local-system-fixture",
        "COWORLD_SOURCE_REVISION": "local-system-fixture",
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
        "COWORLD_LLM_MODEL": "local/escrow-capture-sentinel",
    }
    if args.no_capture:
        del env["COGAME_SAVE_TRAJECTORY_URI"]
    elif args.mode == "collision":
        env["COGAME_SAVE_TRAJECTORY_URI"] = env["COGAME_RESULTS_URI"]
    elif args.mode == "errors":
        env["COGAME_SAVE_TRAJECTORY_URI"] = (
            f"http://127.0.0.1:{fixture.server_port}/private-trajectory"
        )
    processes, logs = [], []
    audits = []

    def audit(command, child_env):
        assert not any(
            k.startswith(("ANTHROPIC_", "AWS_", "BEDROCK_", "OPENAI_"))
            for k in child_env
        )
        audits.append(
            {
                "command": command,
                "parent_env_keys": sorted(os.environ),
                "child_env_keys": sorted(child_env),
                "routing": "explicit loopback sentinel only",
                "provider_credentials_absent": True,
            }
        )
        (output / "environment-audit.json").write_text(
            json.dumps(audits, indent=2) + "\n"
        )

    started = time.monotonic()
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        audit([str(args.game.resolve())], env)
        game = subprocess.Popen(
            [str(args.game.resolve())], env=env, stdout=log, stderr=subprocess.STDOUT
        )
        processes.append(game)
        healthy_by = time.monotonic() + 20
        while True:
            assert game.poll() is None, "game exited before readiness"
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/healthz", timeout=1
                ):
                    break
            except OSError:
                assert time.monotonic() < healthy_by, "health deadline"
                time.sleep(0.05)
        with connect(f"ws://127.0.0.1:{port}/global", open_timeout=3) as viewer:
            first = json.loads(viewer.recv(timeout=3))
            assert first["type"] == "state" and first["game"] == "escrow"
            viewer.ping(b"local-before-model").wait(timeout=3)
            for seat in range(4):
                player_env = clean | {
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=local-token-{seat}",
                    "PLAYER_PROMPT": f"local-operator-canary-{seat}",
                }
                log = (output / f"player-{seat}.log").open("w")
                logs.append(log)
                audit([str(args.player.resolve())], player_env)
                processes.append(
                    subprocess.Popen(
                        [str(args.player.resolve())],
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            next_measurement = 0.0
            while game.poll() is None:
                assert time.monotonic() - started < 180, "native180s wall guard"
                size = sum(f.stat().st_size for f in output.rglob("*") if f.is_file())
                assert size < 24 * 1024**2, "per-fixture24MiB artifact guard"
                assert shutil.disk_usage(output).free >= 2 * 1024**3, "native2GiB floor"
                if time.monotonic() >= next_measurement:
                    record = {
                        "elapsed_seconds": time.monotonic() - started,
                        "http_calls": len(calls),
                        "artifact_bytes": size,
                        "disk_free_bytes": shutil.disk_usage(output).free,
                        "live_owned_processes": sum(
                            p.poll() is None for p in processes
                        ),
                    }
                    try:
                        measured = subprocess.run(
                            [
                                "ps",
                                "-o",
                                "pid=,rss=,time=",
                                "-p",
                                ",".join(str(p.pid) for p in processes),
                            ],
                            capture_output=True,
                            text=True,
                            check=True,
                            timeout=2,
                        )
                        record["process_resources"] = [
                            {
                                "pid": int(parts[0]),
                                "rss_kib": int(parts[1]),
                                "cpu_time_hms": parts[2],
                            }
                            for line in measured.stdout.splitlines()
                            if len(parts := line.split()) == 3
                        ]
                    except (OSError, subprocess.SubprocessError) as error:
                        record["process_resources"] = None
                        record["resource_gap"] = type(error).__name__
                    with (output / "metrics.jsonl").open("a") as metrics:
                        metrics.write(json.dumps(record) + "\n")
                    next_measurement = time.monotonic() + 1
                time.sleep(0.2)
            assert game.returncode == 0
        for process in processes[1:]:
            assert process.wait(timeout=10) == 0
        result = json.loads((output / "results.json").read_text())
        assert result["reason"] == "complete" and result["turns"] == config["turns"], (
            result
        )
        assert not errors
        if args.mode in {
            "normal",
            "rich",
            "normalization",
            "grammar",
            "fidelity",
            "collision",
        }:
            assert len(calls) >= 4 * config["turns"]
        if args.mode in {"normal", "collision"}:
            assert len(calls) == 4 * config["turns"]
            for start in range(0, len(calls), 4):
                assert {v["slot"] for v in calls[start : start + 4]} == set(range(4))
        replay = (output / "replay.json").read_text()
        assert (
            "local-operator-canary" not in replay
            and "X-Softmax-Llm-Call-Id" not in replay
        )
        (output / "loopback-http.json").write_text(json.dumps(calls, indent=2) + "\n")
        (output / "proof.json").write_text(
            json.dumps(
                {
                    "turns": config["turns"],
                    "synthetic_http_calls": len(calls),
                    "native_turn_batches": config["turns"],
                    "native_request_batches_observed": len(
                        {
                            (
                                call["turn"],
                                "Your previous reply was invalid:"
                                in json.loads(call["request_body"])["messages"][0][
                                    "content"
                                ],
                            )
                            for call in calls
                        }
                    ),
                    "dispatch_spans_seconds": [
                        max(c["request_started"] for c in calls[i : i + 4])
                        - min(c["request_started"] for c in calls[i : i + 4])
                        for i in range(0, len(calls), 4)
                    ],
                    "real_provider_calls": 0,
                    "elapsed_seconds": time.monotonic() - started,
                },
                indent=2,
            )
            + "\n"
        )
        if args.no_capture or args.mode == "collision":
            assert not (output / "trajectory.jsonl").exists()
            if args.mode == "collision":
                assert "collides with public" in (output / "game.log").read_text()
        else:
            assert (output / "trajectory.jsonl").is_file(), (
                "complete native game omitted requested private model capture"
            )
            print(
                json.dumps(
                    {"capture_statuses": check_capture(output, calls, args.mode)}
                )
            )
        print(
            f"PASS full{config['turns']}-turn native game,{len(calls)} batched local-only calls; capture_enabled={not args.no_capture}"
        )
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        fixture.shutdown()
        for log in logs:
            log.close()


if __name__ == "__main__":
    main()
