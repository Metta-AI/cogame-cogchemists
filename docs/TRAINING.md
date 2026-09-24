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

`train.jsonl` and `validation.jsonl` split complete games by seed. The
manifest records source revision, variant, final scores, and row counts.
Ten matches per variant yielded 384 training and 96 validation decisions.
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
