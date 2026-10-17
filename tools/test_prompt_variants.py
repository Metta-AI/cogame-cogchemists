"""Complete ordinary games verify wording, private views, actions, and numeric parity."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

BINARY = str(Path(sys.argv[1]).resolve())
MANIFEST = str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json")
TRAIN = ["canonical", "plain", "numbered", "questions", "reordered"]
DIRECT = TRAIN + ["heldout-briefing", "heldout-reference"]


def request(process, command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


for game in ("standard", "silent-academy"):
    with subprocess.Popen(
        [BINARY, MANIFEST, game, "--language"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        for seed in ("17", "946001"):
            baseline = None
            direct_systems = []
            for choice, prompt_seed in [(v, 0) for v in DIRECT] + [
                ("mixed", i) for i in range(5)
            ]:
                obs = request(
                    process,
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 4,
                        "split": "validation" if seed == "17" else "test",
                        "promptVariant": choice,
                        "promptSeed": prompt_seed,
                    },
                )
                trace = []
                systems = {}
                while obs["kind"] == "decision":
                    seat = obs["seat"]
                    view = obs["semantic_view"]
                    meta = view.pop("prompt_template")
                    selected = TRAIN[prompt_seed] if choice == "mixed" else choice
                    assert (
                        meta["bank"],
                        meta["variant"],
                        meta["selection"],
                        meta["seed"],
                    ) == ("cogchemists-rules-v1", selected, choice, prompt_seed)
                    messages = obs["messages"]
                    assert obs["inference_mode"] == "text_action"
                    for message in messages:
                        assert (
                            meta[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    system, user = [message["content"] for message in messages]
                    assert (
                        "prompt_template" not in user and "prompt_selection" not in user
                    )
                    assert systems.setdefault(seat, system) == system
                    assert view["slot"] == seat and "chemistry" not in view
                    for other in range(4):
                        if other != seat:
                            assert f"PRIVATE-{other}" not in user
                        assert not {"hand", "grid", "facts", "notes"}.intersection(
                            view["table"][other]
                        )
                    if len(trace) >= 4:
                        assert view["you"]["notes"] == f"PRIVATE-{seat}"
                    action = json.loads(
                        request(process, {"kind": "teacher"})["response"]
                    )
                    action["notes"] = f"PRIVATE-{seat}"
                    response = request(
                        process,
                        {
                            "kind": "step",
                            "decision_id": obs["decision_id"],
                            "response": json.dumps(action),
                        },
                    )
                    assert (
                        response["kind"] == "accepted" and response["action"] == action
                    )
                    trace.append((view, user, action))
                    obs = response["observation"]
                    assert len(trace) <= 48
                assert (
                    obs["kind"] == "terminal" and len(trace) == 48 and len(systems) == 4
                )
                result = trace, obs
                if baseline is None:
                    baseline = result
                assert result == baseline
                if choice == "mixed":
                    assert systems == direct_systems[prompt_seed]
                else:
                    assert systems not in direct_systems
                    direct_systems.append(systems)
            print(game, seed, "12 complete text games PASS", flush=True)
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0

for language in (False, True):
    invalids = [
        {"promptVariant": v}
        for v in ("heldout-briefing", "heldout-reference", "unknown", "mixed")
    ]
    invalids += [{"split": "unknown"}]
    invalids += [
        {"promptVariant": "mixed", "promptSeed": seed} for seed in (-1, True, 1.5)
    ]
    if not language:
        invalids.append({"promptVariant": "plain"})
    for invalid in invalids:
        result = subprocess.run(
            [BINARY, MANIFEST, "standard"] + (["--language"] if language else []),
            input=json.dumps(
                {"kind": "reset", "seed": "17", "players": 4, "split": "train"}
                | invalid
            )
            + "\n",
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout

if len(sys.argv) == 3:
    for game in ("standard", "silent-academy"):
        processes = [
            subprocess.Popen(
                [str(Path(binary).resolve()), MANIFEST, game],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            for binary in (sys.argv[2], BINARY)
        ]
        try:
            for seed in ("17", "946001"):
                observations = [
                    request(p, {"kind": "reset", "seed": seed, "players": 4})
                    for p in processes
                ]
                while observations[0]["kind"] == "decision":
                    assert observations[0] == observations[1]
                    encodings = [request(p, {"kind": "encode"}) for p in processes]
                    assert encodings[0] == encodings[1]
                    assert (
                        len(encodings[0]["values"]) == 131
                        and len(encodings[0]["actions"]) == 3
                    )
                    actions = [
                        request(p, {"kind": "teacher"})["response"] for p in processes
                    ]
                    assert actions[0] == actions[1]
                    results = [
                        request(
                            p,
                            {
                                "kind": "step",
                                "decision_id": obs["decision_id"],
                                "response": action,
                            },
                        )
                        for p, obs, action in zip(
                            processes, observations, actions, strict=True
                        )
                    ]
                    assert results[0] == results[1]
                    observations = [result["observation"] for result in results]
                assert observations[0] == observations[1]
            print(game, "two original numeric comparisons PASS", flush=True)
        finally:
            for process in processes:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
