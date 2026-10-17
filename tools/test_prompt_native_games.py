"""Full native-player games exercise actual failed requests and consumed fallbacks."""

import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

VARIANTS = ["canonical", "plain", "numbered", "questions", "reordered"]


def metadata(messages, choice, seed):
    return {
        "bank": "cogchemists-rules-v1",
        "variant": VARIANTS[seed] if choice == "mixed" else choice,
        "selection": choice,
        "seed": seed,
        "system_sha256": hashlib.sha256(messages[0]["content"].encode()).hexdigest(),
        "user_sha256": hashlib.sha256(messages[1]["content"].encode()).hexdigest(),
    }


GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
SOURCE = sys.argv[4]
ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())

for variant in manifest["variants"]:
    baselines = {}
    cases = [
        ("model", wording)
        for wording in VARIANTS + ["heldout-briefing", "heldout-reference"]
    ]
    cases += [("assayer", "canonical"), ("quack", "canonical"), ("quack", "plain")]
    for mode, choice in cases:
        prompt_seed = 0
        output = OUTPUT / f"{variant['id']}-{mode}-{choice}-{prompt_seed}"
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
        config = variant["game_config"] | {
            "tokens": ["0", "1", "2", "3"],
            "seed": 17,
            "promptVariant": choice,
            "promptSeed": prompt_seed,
        }
        (output / "config.json").write_text(json.dumps(config))
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        with socket.socket() as closed_endpoint:
            closed_endpoint.bind(("127.0.0.1", 0))
            environment = dict(os.environ)
            for key in (
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_API_KEY_URI",
                "AWS_BEARER_TOKEN_BEDROCK",
                "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            ):
                environment.pop(key, None)
            environment.update(
                COGAME_HOST="127.0.0.1",
                COGAME_PORT=str(port),
                COGAME_CONFIG_URI=(output / "config.json").as_uri(),
                COGAME_RESULTS_URI=(output / "results.json").as_uri(),
                COGAME_SAVE_REPLAY_URI=(output / "replay.json").as_uri(),
                COGAME_SAVE_TRAJECTORY_URI=(output / "trajectory.jsonl").as_uri(),
                COWORLD_SOURCE_REVISION=SOURCE,
                COWORLD_EPISODE_ID=str(uuid.uuid4()),
                COWORLD_GAME_VERSION="source-prompt-validation",
                COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_endpoint.getsockname()[1]}",
                COWORLD_LLM_MODEL="closed-endpoint-validation",
            )
            processes, logs = [], []
            try:
                log = (output / "game.log").open("w")
                logs.append(log)
                game = subprocess.Popen(
                    [str(GAME)], cwd=ROOT, env=environment, stdout=log, stderr=log
                )
                processes.append(game)
                ready_deadline = time.monotonic() + 30
                while True:
                    with socket.socket() as probe:
                        ready = probe.connect_ex(("127.0.0.1", port)) == 0
                    if ready:
                        break
                    assert game.poll() is None and time.monotonic() < ready_deadline
                    time.sleep(0.02)
                for seat in range(4):
                    player_env = environment | {
                        "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}",
                        "PLAYER_SCRIPTED": "" if mode == "model" else mode,
                        "PLAYER_PROMPT": f"PRIVATE-OPERATOR-{seat}: maximize your score.",
                    }
                    log = (output / f"player-{seat}.log").open("w")
                    logs.append(log)
                    processes.append(
                        subprocess.Popen(
                            [str(PLAYER)],
                            cwd=ROOT,
                            env=player_env,
                            stdout=log,
                            stderr=log,
                        )
                    )
                deadline = time.monotonic() + 1200 + 60
                for process in processes:
                    assert (
                        process.wait(timeout=max(1, deadline - time.monotonic())) == 0
                    )
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
                for log in logs:
                    log.close()
        events = [
            json.loads(line)
            for line in (output / "trajectory.jsonl").read_text().splitlines()
        ]
        assert len(events) == 49 and events[-1]["status"] == "completed"
        assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        trace = []
        conflicts = 0
        for event in events[:-1]:
            seat = int(event["seat"])
            view = event["observation"]
            assert view.pop("prompt_selection") == {
                "bank": "cogchemists-rules-v1",
                "variant": choice,
                "selection": choice,
                "seed": 0,
            }
            prompt_attempts = view.pop("prompt_attempts")
            attempts = event["attempts"]
            if mode == "model":
                assert [a["origin"] for a in attempts] == ["model", "model", "fallback"]
                assert (
                    event["action_status"] == "fallback"
                    and event["selected_attempt_id"] is None
                )
                prompted = attempts[:2]
            else:
                assert len(attempts) == 1 and attempts[0]["origin"] == "teacher"
                assert attempts[0]["policy"] == f"scripted-{mode}"
                assert attempts[0]["parsed_action"] == json.loads(
                    attempts[0]["response"]
                )
                prompted = attempts
                if event["action_status"] == "accepted":
                    assert attempts[0]["accepted"]
                    assert event["selected_attempt_id"] == attempts[0]["attempt_id"]
                    assert event["executed_action"] == attempts[0]["parsed_action"]
                else:
                    conflicts += 1
                    assert (
                        event["action_status"] == "fallback"
                        and not attempts[0]["accepted"]
                    )
                    assert (
                        event["selected_attempt_id"] is None
                        and attempts[0]["rejection_reason"]
                    )
                    assert event["executed_action"]["action"] == "pass"
                    assert event["fallback_origin"] == "phase-conflict-pass"
            assert prompt_attempts == [
                {
                    "attempt_id": a["attempt_id"],
                    "prompt_template": metadata(a["prompt"], choice, 0),
                }
                for a in prompted
            ]
            users = []
            for attempt in prompted:
                assert (
                    attempt["raw_response"] is None
                    and attempt["platform_call_id"] is None
                )
                assert [m["role"] for m in attempt["prompt"]] == ["system", "user"]
                system, user = [m["content"] for m in attempt["prompt"]]
                if mode == "model":
                    assert not attempt["accepted"] and attempt["rejection_reason"]
                    assert attempt["request"]["system"] == system
                    assert attempt["request"]["messages"] == [
                        {"role": "user", "content": user}
                    ]
                else:
                    assert attempt["request"] is None
                assert f"PRIVATE-OPERATOR-{seat}" in user
                for other in range(4):
                    if other != seat:
                        assert f"PRIVATE-OPERATOR-{other}" not in user
                assert "prompt_selection" not in user and "prompt_template" not in user
                users.append(user)
            if mode == "model":
                assert users[1].startswith(
                    users[0] + "\n\nYour previous reply was invalid."
                )
                assert attempts[2]["prompt"] is None and attempts[2]["request"] is None
            trace.append(
                (view, users, attempts[-1]["parsed_action"], event["executed_action"])
            )
        if mode == "quack":
            assert conflicts > 0, "full-game fixture must exercise initiative conflicts"
        replay_text = (output / "replay.json").read_text()
        assert (
            "PRIVATE-OPERATOR" not in replay_text
            and "prompt_template" not in replay_text
        )
        replay = json.loads(replay_text)
        results = json.loads((output / "results.json").read_text())
        assert results["reason"] == "complete" and results["rounds"] == 6
        assert replay["results"] == results == events[-1]["outcome"]
        result = trace, replay, results
        assert baselines.setdefault(mode, result) == result
        print(
            variant["id"],
            mode,
            choice,
            conflicts,
            "conflict passes; 48 native decisions; complete replay and score parity PASS",
            flush=True,
        )
