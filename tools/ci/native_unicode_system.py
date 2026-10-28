"""Exercise partial native HTTP -> parser/apply -> private writer; never a full game."""

import argparse
import base64
import http.server
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from uuid import UUID, uuid4


def scalar_json(node):
    if isinstance(node, str):
        node.encode("utf8", errors="strict")
    elif isinstance(node, dict):
        for key, value in node.items():
            scalar_json(key)
            scalar_json(value)
    elif isinstance(node, list):
        for value in node:
            scalar_json(value)


def verify(output, calls):
    rows = [
        json.loads(line)
        for line in (output / "trajectory.jsonl")
        .read_text(encoding="utf8")
        .splitlines()
    ]
    scalar_json(rows)
    native = json.loads((output / "native-summary.json").read_text())
    assert not native["native_done"] and native["turns_applied"] == 3
    decisions = [row for row in rows if row["event_type"] == "decision"]
    assert len(decisions) == 12 and rows[-1]["status"] == "failed"
    wire = {call["call_id"]: call for call in calls}
    forensic = 0
    for row in decisions:
        observation = row["observation"]
        if "invalid_native_evidence_json_b64" not in observation:
            for attempt in row["attempts"]:
                UUID(attempt["platform_call_id"])
            continue
        forensic += 1
        assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
        assert row["executed_action"] is None and row["attempts"] == []
        raw = base64.b64decode(
            observation["invalid_native_evidence_json_b64"], validate=True
        )
        original = json.loads(raw.decode("utf8", errors="surrogateescape"))
        turn, seat = map(int, row["decision_id"].split("-"))
        snapshot = next(
            n for n in native["notes"] if n["turn"] == turn - 1 and n["seat"] == seat
        )
        assert (
            list(
                original["executed_action"]["notes"].encode(
                    "utf8", errors="surrogateescape"
                )
            )
            == snapshot["installed_note_bytes"]
        )
        for index, attempt in enumerate(original["attempts"]):
            UUID(attempt["platform_call_id"])
            call = wire[attempt["platform_call_id"]]
            assert attempt["response_body_b64"] == call["response_b64"]
            assert (
                original["observation"]["native_requests"][index]["body_b64"]
                == call["request_b64"]
            )
    assert forensic == 7
    for index, text in ((0, "café"), (1, "😀"), (6, "safe")):
        assert decisions[index]["action_status"] == "accepted"
        assert decisions[index]["executed_action"]["notes"] == text
    # The earlier low surrogate persists into the next request, which must also be quarantined.
    assert "invalid_native_evidence_json_b64" in decisions[7]["observation"]
    return {
        "strict_scalar_json": True,
        "forensic_rows": forensic,
        "exact_original_bytes": True,
        "full_games": 0,
        "provider_calls": 0,
    }


def main():
    allowed = {
        key: os.environ[key]
        for key in ("PATH", "HOME", "TMPDIR", "LANG")
        if key in os.environ
    }
    if set(os.environ) - set(allowed) - {"LC_CTYPE", "__CF_USER_TEXT_ENCODING"}:
        os.execve(sys.executable, [sys.executable, *sys.argv], allowed)
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nim", type=Path, required=True)
    parser.add_argument("--nimcache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    binary = output / "native-unicode-component"
    paths = [
        line.strip()
        for line in (root / "nim.cfg").read_text().splitlines()
        if line.strip().startswith("--path:")
    ]
    assert paths and shutil.disk_usage(output).free >= 2 * 1024**3
    command = [
        str(args.nim.resolve()),
        "c",
        "-d:release",
        "--hints:off",
        "--skipUserCfg:on",
        "--skipParentCfg:on",
        "--nimcache:" + str(args.nimcache.resolve()),
        "-o:" + str(binary),
        "--path:src",
        *["--path:" + line.split(":", 1)[1].strip('"') for line in paths],
        "tools/ci/native_unicode_component.nim",
    ]
    card = {
        "compile_command": command,
        "parent_env_keys": sorted(os.environ),
        "compile_env_keys": sorted(allowed),
    }

    def save():
        (output / "proof.json").write_text(json.dumps(card, indent=2) + "\n")

    save()
    with (output / "compile.log").open("w") as log:
        subprocess.run(
            command,
            cwd=root,
            env=allowed,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
            timeout=240,
        )
    cases = [
        ('{"notes":"caf\\u00e9"}', None),
        ('{"notes":"\\ud83d\\ude00"}', None),
        ('{"notes":"\\ud800"}', None),
        ('{"notes":"\\udc00"}', None),
        ('{"notes":"BYTE"}', b"\x80"),
        ('{"\\ud800":1}', None),
        ('{"not\\u0065s":"safe"}', None),
        ('{"\\udc00":1}', None),
        ('{"notes":"BYTE"}', b"\xc0\x80"),
        ('{"notes":"BYTE"}', b"\xf4\x90\x80\x80"),
        ('{"notes":"BYTE"}', b"\xe2\x28\xa1"),
        ('{"notes":"BYTE"}', b"\xe2\x82"),
    ]
    calls = []
    started = time.monotonic()

    class Sentinel(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_POST(self):
            assert self.path == "/v1/messages"
            body = self.rfile.read(int(self.headers["Content-Length"]))
            # Only the loopback inspector decodes malformed requests permissively; wire bytes stay unchanged.
            request = json.loads(body.decode("utf8", errors="surrogateescape"))
            assert (
                request["model"] == "local/unicode-sentinel"
                and request["max_tokens"] == 1100
            )
            user = request["messages"][0]["content"]
            turn, seat = (
                int(user.split(" of ")[0].split()[1]),
                int(self.headers["X-Coworld-Player-Slot"]),
            )
            text, invalid = cases[turn * 4 + seat]
            if "Your previous reply was invalid:" in user:
                text, invalid = "{}", None
            payload = json.dumps(
                {
                    "id": "local-message",
                    "content": [{"type": "text", "text": text}],
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                }
            ).encode()
            if invalid is not None:
                payload = payload.replace(b"BYTE", invalid)
            call = {
                "call_id": str(uuid4()),
                "request_b64": base64.b64encode(body).decode(),
                "response_b64": base64.b64encode(payload).decode(),
                "elapsed_seconds": time.monotonic() - started,
            }
            calls.append(call)
            assert len(calls) <= 24
            with (output / "wire.jsonl").open("a") as stream:
                stream.write(json.dumps(call) + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("X-Softmax-Llm-Call-Id", call["call_id"])
            self.end_headers()
            self.wfile.write(payload)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    child = allowed | {
        "COWORLD_EPISODE_ID": "local-partial-unicode",
        "COWORLD_GAME_VERSION": "local-component",
        "COWORLD_SOURCE_REVISION": "local-source-probe",
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
        "COWORLD_LLM_MODEL": "local/unicode-sentinel",
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
    }
    run_command = [str(binary), str(output)]
    card.update(
        run_command=run_command,
        run_env_keys=sorted(child),
        partial_turns=3,
        configured_turns=4,
    )
    save()
    process = None
    try:
        with (output / "run.log").open("w") as log:
            process = subprocess.Popen(
                run_command, env=child, stdout=log, stderr=subprocess.STDOUT
            )
            while process.poll() is None:
                size = sum(p.stat().st_size for p in output.rglob("*") if p.is_file())
                assert time.monotonic() - started < 30 and size <= 8 * 1024**2
                assert shutil.disk_usage(output).free >= 2 * 1024**3
                with (output / "metrics.jsonl").open("a") as stream:
                    stream.write(
                        json.dumps(
                            {
                                "elapsed_seconds": time.monotonic() - started,
                                "http_calls": len(calls),
                                "artifact_bytes": size,
                            }
                        )
                        + "\n"
                    )
                time.sleep(0.05)
            assert process.returncode == 0
        card.update(
            verify(output, calls),
            fixture_http_calls=len(calls),
            execution_seconds=time.monotonic() - started,
        )
        save()
        print(json.dumps(card))
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        server.shutdown()


if __name__ == "__main__":
    main()
