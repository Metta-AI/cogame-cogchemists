# Cogchemists post-training

The exporter runs complete production matches with the shipped `assayer`
teacher. Each phase records the acting seat's hosted system and user prompts
and a reply accepted by the game's parser. Four decisions are made against
one phase state, then resolve in initiative order through the native
simulator. Both certified variants are supported.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cogchemists-posttrain tools/export_posttrain.nim
/tmp/cogchemists-posttrain /tmp/cogchemists-standard-dataset 10 standard
/tmp/cogchemists-posttrain /tmp/cogchemists-silent-dataset 10 silent-academy
python3 tools/test_export_posttrain.py /tmp/cogchemists-posttrain
```

`trajectories.jsonl` contains private complete-episode events. The exporter
requires a clean committed source and refuses existing output paths. Each phase
uses one frozen observation for all four proposals, then records actual outcomes
after initiative resolution. A conflicted proposal is rejected; its executed pass
is fallback evidence and cannot become an accepted teacher target.

Convert the event stream using the shared Metta package:

```sh
uv run --package metta-posttraining python - <<'PYTHON'
from pathlib import Path
from coworld.decision_trajectory import export_complete_episodes, read_trajectory_jsonl

source = Path("/tmp/cogchemists-standard-dataset/trajectories.jsonl")
assert export_complete_episodes(
    read_trajectory_jsonl(source), source.parent / "complete-episodes.jsonl"
) == 10
PYTHON
```

Conversion does not authorize training. The application importer
`metta_training.posttrain.hosted.export_hosted` requires external authority bound
to the exact complete-episode SHA256 and source revision. Select
`scripted-assayer` explicitly. Serving receipts remain null for scripted actions.
The family `cogchemists-SEED` keeps wordings and both game variants together when
splitting data.

## Rule wording

`promptVariant` selects `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` selects one of those five using an explicit nonnegative
`promptSeed`, independently of game randomness. Selection stays fixed throughout
the episode, including retries. `heldout-briefing` and `heldout-reference` are
reserved for evaluation; training resets and the teacher exporter reject them.
Only the introductory role, participants, duration, and competition description
vary. Chemistry, scoring, action rules, private observations, and operator guidance
retain their original definitions.

The text bridge accepts full hosted JSON actions and preserves simultaneous
phase resolution. Bridge acceptance means the proposal was queued; an earlier
seat can still invalidate it during resolution. Use engine-resolved complete
episodes for authoritative executed-action targets:

```sh
/tmp/cogchemists-train-bridge coworld_manifest_template.json standard --language
/tmp/cogchemists-posttrain /tmp/cogchemists-plain 10 standard plain 0
```

Text decisions include private `semantic_view.prompt_template` metadata with the
bank, selected wording, independent seed, and exact system/user SHA256 values.
These metadata fields are not included in model messages.

Historical CPU pilots used the earlier row exporter: a single optimizer step
changed four-example validation loss from 1.72949 to 1.72419 for standard and
1.73312 to 1.72767 for silent academy. Those results do not qualify the new
candidate corpus or establish improved league play or paraphrase robustness.

## Private native evidence

Set `COGAME_SAVE_TRAJECTORY_URI` to a private artifact destination, together with
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`.
The engine records actual request bodies, system/user messages, responses,
retries, parsed proposals, and resolved actions. Authorization headers are never
recorded. Request failures retain their rejection reason and executed fallback.
Explicit scripted policies are teachers; externally submitted actions remain
unknown, and unavailable external actions fall back to the assayer.

Private observations carry `prompt_selection` and per-attempt `prompt_attempts`
hashes. These fields stay out of spectator replays and model messages. This older
game-owned transport does not provide authenticated serving receipts or token
probabilities; captured requests alone do not qualify on-policy training data.

Run the full workflows after compiling the binaries:

```sh
python3 tools/test_prompt_variants.py /tmp/cogchemists-train-bridge
python3 tools/test_prompt_native_games.py /tmp/cogchemists-game /tmp/cogchemists-player /tmp/cogchemists-native-prompts "$(git rev-parse HEAD)"
```

The native panel runs both published variants under all seven direct wordings.
It also runs each variant with an explicit assayer and two quack wordings. Quack
games must exercise initiative conflicts and record rejected proposals as passes.
Four actual player processes register private operator prompts. A closed local
endpoint produces two real failed requests per decision, followed by engine
fallback. Ordinary rounds, pacing, and budgets stay unchanged. The checks compare
private observations, executed actions, complete replays, and scores. This tests
prompt plumbing and deterministic semantics, not model robustness or learning.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes the hosted prompts and 131 numeric values
from each seat's permitted observation. Three actions select the published
`assayer` or `quack` policy, or pass. All four seats decide against the same
phase state before the native simulator resolves them in initiative order.
Scores remain the game's reputation plus coin value. Utilities use
`score / (abs(score) + 20)` to fit the RL contract's [-1, 1] range while
preserving each seat's score ordering. Arbitrary ingredient and theory
replies use the explicit `--language` bridge mode above.

```sh
nim c -d:release --path:src -o:/tmp/cogchemists-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cogchemists-train-bridge
```

The bridge has four seats and supports `standard` and `silent-academy`.
Use absolute binary and manifest paths when configuring the shared Coworld
collector. Numeric requests use the two-argument command; language collection
adds `--language`. Keep wordings of one game seed in the same data split.

Historical pilots completed 512 Metta RL timesteps per variant. At epoch ten, evaluation
mean return was 0.446 for standard and 0.280 for silent academy. These
pilots verify the numeric observation and reward path, not improved play.

Native PufferLib completed 4,096 CUDA timesteps per variant on metta1.
Checkpoint reload and held-out seeds 101 and 102 each reported mean score
13.2 for both variants. Checkpoint SHA-256 values were
`2bd800ce9edbdb762dc0fa787f3192529c02453fea271ec83557cea2ff1c1779`
for standard and
`6531c2421b3450ac5b99f50d8953b978abf8befc9d820319b828ea2b6493aea8`
for silent academy.
