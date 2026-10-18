"""Complete published Escrow games through original numeric and full text interfaces."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE, ORIGINAL = map(lambda value: Path(value).resolve(), sys.argv[1:3])
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(
    variant, seed, wording="canonical", prompt_seed=0, original=False, private=False
):
    command = [
        str(ORIGINAL if original else BRIDGE),
        str(ROOT / "coworld_manifest_template.json"),
        variant,
    ]
    if not original:
        command.append("text")
    with subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 4,
                "seed": str(seed),
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, systems = [], {}
        frozen = None
        while observation["kind"] == "decision":
            index = observation["decision_id"]
            seat = index % 4
            assert observation["seat"] == seat and index == len(trace)
            messages = observation["messages"]
            systems.setdefault(seat, messages[0]["content"])
            assert systems[seat] == messages[0]["content"]
            if not original:
                view = observation["semantic_view"]
                metadata = view["prompt_template"]
                assert metadata["bank"] == "escrow-rules-v1"
                assert metadata["variant"] == (
                    WORDINGS[prompt_seed] if wording == "mixed" else wording
                )
                for message in messages:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                public = (view["public_floor"], view["board"], view["recent"])
                if seat == 0:
                    frozen = public
                assert public == frozen
                assert all(
                    "notes" not in other and "notes" not in other["state"]
                    for other in view["public_floor"]
                )
                if private:
                    for other in range(4):
                        if other != seat:
                            assert (
                                f"PRIVATE-{other}-"
                                not in json.dumps(view) + messages[1]["content"]
                            )
                    if index >= 4:
                        assert view["notes"].startswith(f"PRIVATE-{seat}-")
                        assert len(view["notes"]) == 600
            teacher = json.loads(request({"kind": "teacher"})["response"])
            if private:
                teacher["give"] = [
                    {
                        "to": view["public_floor"][(seat + 1) % 4]["name"],
                        "n": "1.0",
                        "good": " hearts ",
                    }
                ]
                teacher["sign"] = [
                    " " + contract.lower() + " " for contract in teacher["sign"]
                ]
                teacher["notes"] = f"PRIVATE-{seat}-" + "λ" * 700
                teacher["say"] = f"PUBLIC-{seat}\n" + "δ" * 180
            result = request(
                {"kind": "step", "decision_id": index, "response": json.dumps(teacher)}
            )
            assert result["kind"] == "accepted"
            if private:
                assert len(result["action"]["notes"]) == 600
                assert result["action"]["give"] == [
                    {"to": (seat + 1) % 4, "n": 1, "good": "HEARTS"}
                ]
                assert "\n" not in result["action"]["say"]
            else:
                assert result["action"] == teacher
            trace.append(messages[1]["content"])
            observation = result["observation"]
        assert len(trace) == (64 if variant == "standard" else 32)
        assert set(observation["scores"]) == {str(seat) for seat in range(4)}
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        return trace, observation, systems


for variant in ("standard", "sprint"):
    for seed in (17, 946001):
        baseline = play(variant, seed, original=True)
        canonical = None
        distinct = []
        for wording, prompt_seed in [(name, 0) for name in WORDINGS] + [
            ("mixed", index) for index in range(5)
        ]:
            trace, outcome, systems = play(variant, seed, wording, prompt_seed)
            assert (trace, outcome) == baseline[:2]
            if wording == "canonical":
                assert systems == baseline[2]
                canonical = systems
            if wording == "mixed":
                assert systems == distinct[prompt_seed]
            else:
                distinct.append(systems)
        assert all(len({entry[seat] for entry in distinct}) == 7 for seat in range(4))
    play(variant, 17, private=True)
    print(
        variant,
        "24 matched text games, two original games, and private text normalization PASS",
        flush=True,
    )
print("50 complete text games and four original numeric games PASS")
for wording in WORDINGS[-2:]:
    rejected = subprocess.run(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), "standard", "text"],
        input=json.dumps(
            {
                "kind": "reset",
                "players": 4,
                "seed": "17",
                "promptVariant": wording,
                "split": "train",
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert (
        rejected.returncode != 0
        and "held-out wording is evaluation-only" in rejected.stderr
    )
print("Held-out training collection rejected PASS")
