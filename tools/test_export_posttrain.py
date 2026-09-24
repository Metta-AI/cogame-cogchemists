"""Check complete Cogchemists datasets and hosted prompt fields."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


BINARY = Path(sys.argv[1]).resolve()
ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory() as directory:
    for variant in ("standard", "silent-academy"):
        output = Path(directory) / variant
        subprocess.run([str(BINARY), str(output), "10", variant], cwd=ROOT, check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert manifest["game"] == "cogchemists" and manifest["variant"] == variant
        assert len(manifest["runs"]) == 10
        assert len(train) == manifest["train_examples"] == 384
        assert len(validation) == manifest["validation_examples"] == 96
        assert all(run["rounds"] == 6 and len(run["scores"]) == 4
                   for run in manifest["runs"])
        for row in train + validation:
            assert row["game"] == "cogchemists"
            assert row["prompt"][0]["role"] == "system"
            assert row["prompt"][1]["role"] == "user"
            assert "YOUR HAND:" in row["prompt"][1]["content"]
            assert "LEGAL MOVES" in row["prompt"][1]["content"]
            assert "local-seat" not in json.dumps(row["prompt"])
            reply = json.loads(row["completion"][0]["content"])
            assert set(reply) == {"action", "a", "b", "signature", "artifact", "say", "notes"}
        print(variant, len(train), len(validation))
