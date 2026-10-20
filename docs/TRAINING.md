# Cogchemists post-training

The exporter runs complete production matches with the shipped `assayer`
teacher. Each phase records the acting seat's hosted system and user prompts
and a reply accepted by the game's parser and initiative resolution. Four decisions are made against
one phase state, then resolve in initiative order through the native
simulator. Both certified variants are supported.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cogchemists-posttrain tools/export_posttrain.nim
/tmp/cogchemists-posttrain /tmp/cogchemists-standard-dataset 10 standard
/tmp/cogchemists-posttrain /tmp/cogchemists-silent-dataset 10 silent-academy
python3 tools/test_export_posttrain.py /tmp/cogchemists-posttrain
```

`train.jsonl` and `validation.jsonl` split complete games by seed. The
manifest records source revision, variant, final scores, and row counts.
Only proposals accepted after initiative resolution become examples. Conflicted
proposals and their forced passes are excluded; the manifest counts both accepted
examples and rejected proposals. The requested number of complete games is unchanged.
The exporter refuses to overwrite an output directory.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/cogchemists-standard-dataset \
  --output /tmp/cogchemists-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

These examples distill the scripted teacher and preserve each seat's private
experiment history. They do not establish improved league play.

All 960 examples fit 4,096 tokens with the local WordLevel smoke tokenizer.
One CPU optimizer step reduced four-example validation loss from 1.72949 to
1.72419 for standard and from 1.73312 to 1.72767 for silent academy. This
verifies the post-training path.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes the hosted prompts and 131 numeric values
from each seat's permitted observation. Three actions select the published
`assayer` or `quack` policy, or pass. All four seats decide against the same
phase state before the native simulator resolves them in initiative order.
Scores remain the game's reputation plus coin value. Utilities use
`score / (abs(score) + 20)` to fit the RL contract's [-1, 1] range while
preserving each seat's score ordering. Arbitrary ingredient and theory
replies use the post-training path above.

```sh
nim c -d:release --path:src -o:/tmp/cogchemists-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cogchemists-train-bridge
```

From a Metta checkout with the Coworld training stack installed, pass the
absolute bridge binary and manifest paths to `recipes.external.coworld.train`
for native PufferLib or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=4`; both `standard` and `silent-academy` variants are supported.

Both variants completed 512 Metta RL timesteps. At epoch ten, evaluation
mean return was 0.446 for standard and 0.280 for silent academy. These
pilots verify the numeric observation and reward path, not improved play.

Native PufferLib completed 4,096 CUDA timesteps per variant on metta1.
Checkpoint reload and held-out seeds 101 and 102 each reported mean score
13.2 for both variants. Checkpoint SHA-256 values were
`2bd800ce9edbdb762dc0fa787f3192529c02453fea271ec83557cea2ff1c1779`
for standard and
`6531c2421b3450ac5b99f50d8953b978abf8befc9d820319b828ea2b6493aea8`
for silent academy.

## Prompt fuzzing

Select `canonical`, `plain`, `numbered`, `questions`, or `reordered` with
`promptVariant`; `mixed` requires a nonnegative `promptSeed` and selects by
seed modulo five. Selection remains fixed during a game and uses no game randomness.
The v2 bank varies the role, hidden chemistry and simultaneous-resolution briefings.
Mixing rules, action costs, scoring and the response schema remain exact.

Language bridge resets support these fields with `--language`. Held-out briefing
and reference variants require an evaluation split; teacher export rejects them.
Private decision metadata includes the bank and exact system/user message hashes.

Append `PROMPT_VARIANT PROMPT_SEED` to the exporter command. Mixed export advances
the prompt seed separately within each split, keeping all five wordings available
in training despite every-fifth-seed validation. Episode IDs distinguish wordings; scenario-family IDs
exclude wording and game variant, preserving train/validation separation.
Export from a clean committed checkout. Original train/validation JSONL files
remain the dataset interface; no additional hosted capture protocol is introduced.

`tools/test_prompt_variants.py BRIDGE_BINARY` plays 16 complete games across both
variants, seven direct wordings and one mixed selection. The existing exporter
check runs 20 mixed games and checks selection, accepted counts and family splits.
Scripted invariance verifies game mechanics, not learned-policy robustness.
