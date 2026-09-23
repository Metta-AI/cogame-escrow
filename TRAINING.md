# Metta post-training data

The native simulator and published `trader` policy export supervised examples
for both certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/escrow-standard 10 1 standard
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/escrow-sprint 10 1 sprint
```

Each run reads the manifest variant config, adds the per-seat tokens supplied
by the hosted platform, and plays complete seeded games. The exporter freezes
the game state at each simultaneous decision boundary, then records each seat's
hosted system and user prompts and a `trader` move accepted by the game's reply
parser. Parsed moves drive the simulator. Entire games stay in one split. The
manifest records source revision, variant, scores, minted hearts, and row
counts. Existing output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/escrow-standard \
  --output /tmp/escrow-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games yielded 512 training and 128 validation examples for
standard, and 256 training and 64 validation examples for sprint. All 960
examples fit a 4,096-token context with the Qwen2.5-0.5B-Instruct tokenizer
(maximum: 3,181 tokens). One CPU optimizer step per dataset with a local tiny
model verifies the Metta post-training path. These examples distill the
scripted teacher; they do not establish stronger league play.
