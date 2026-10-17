"""Verify complete engine-resolved Cogchemists exports and private prompt evidence."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

BINARY = Path(sys.argv[1]).resolve()
ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory() as directory:
    for variant in ("standard", "silent-academy"):
        baseline = None
        for wording in ("canonical", "plain", "numbered", "questions", "reordered"):
            output = Path(directory) / f"{variant}-{wording}"
            subprocess.run(
                [str(BINARY), str(output), "10", variant, wording, "0"],
                cwd=ROOT,
                check=True,
            )
            manifest = json.loads((output / "manifest.json").read_text())
            source = output / "trajectories.jsonl"
            events = [json.loads(line) for line in source.read_text().splitlines()]
            episodes = [row for row in events if row["event_type"] == "episode"]
            decisions = [row for row in events if row["event_type"] == "decision"]
            assert len(episodes) == len(manifest["runs"]) == 10
            assert len(decisions) == 480
            assert all(row["status"] == "completed" for row in episodes)
            assert {row["seed_family"] for row in episodes} == {
                f"cogchemists-{seed}" for seed in range(1, 11)
            }
            assert {row["source_revision"] for row in events} == {
                manifest["source_revision"]
            }
            assert source.stat().st_mode & 0o777 == 0o600
            assert not (output / "train.jsonl").exists()
            assert not (output / "validation.jsonl").exists()
            trace = []
            for row in decisions:
                assert len(row["attempts"]) == 1
                attempt = row["attempts"][0]
                assert (
                    attempt["origin"] == "teacher"
                    and attempt["policy"] == "scripted-assayer"
                )
                assert (
                    attempt["request"] is None and attempt["platform_call_id"] is None
                )
                assert json.loads(attempt["response"]) == attempt["parsed_action"]
                view = row["observation"]
                metadata = view.pop("prompt_template")
                assert (
                    metadata["bank"],
                    metadata["variant"],
                    metadata["selection"],
                    metadata["seed"],
                ) == ("cogchemists-rules-v1", wording, wording, 0)
                assert [message["role"] for message in attempt["prompt"]] == [
                    "system",
                    "user",
                ]
                for message in attempt["prompt"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                user = attempt["prompt"][1]["content"]
                assert "YOUR HAND:" in user and "LEGAL MOVES" in user
                assert "local-seat" not in json.dumps(attempt["prompt"])
                if row["action_status"] == "accepted":
                    assert attempt["accepted"]
                    assert row["selected_attempt_id"] == attempt["attempt_id"]
                    assert row["executed_action"] == attempt["parsed_action"]
                else:
                    assert (
                        row["action_status"] == "fallback" and not attempt["accepted"]
                    )
                    assert (
                        row["selected_attempt_id"] is None
                        and attempt["rejection_reason"]
                    )
                    assert row["executed_action"]["action"] == "pass"
                trace.append(
                    (
                        view,
                        user,
                        attempt["parsed_action"],
                        row["executed_action"],
                        row["action_status"],
                    )
                )
            result = (
                trace,
                [(row["outcome"], row["participant_outcomes"]) for row in episodes],
            )
            if baseline is None:
                baseline = result
            assert result == baseline
            print(
                variant,
                wording,
                "10 full games and 480 resolved decisions PASS",
                flush=True,
            )
