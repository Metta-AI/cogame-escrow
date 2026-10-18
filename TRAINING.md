# Prompt variants and training

The default `canonical` prompt preserves the original messages. Five training
wordings (`canonical`, `plain`, `numbered`, `questions`, `reordered`) paraphrase
the role introduction. Shared rules, contracts, scoring, and budgets stay fixed.
`mixed` resolves using an explicit nonnegative `promptSeed % 5`, independently
of the simulator seed. Selection stays fixed throughout an episode.
`heldout-briefing` and `heldout-reference` are evaluation-only.

## Complete text actions

The bridge accepts an optional third argument, `text`. It supports the full
contract language, gives, signatures, public speech, and private notes through
the production parser and simulator. Its reset accepts `promptVariant`,
`promptSeed`, and `split`; held-out wordings cannot be used for training.
Observations include exact message hashes and only the acting seat's private notes.
All four observations come from the same frozen turn state.

The existing 71-value numeric bridge and four scripted choices remain available.
See [numeric training](docs/TRAINING.md) for its commands and historical pilots.

## Reviewed candidate exports

Build once and export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/escrow-export tools/export_posttrain.nim
/tmp/escrow-export /tmp/escrow-standard 10 1 standard canonical 0
/tmp/escrow-export /tmp/escrow-sprint 10 1 sprint canonical 0
```

Each export runs complete published games: four players, 16 turns for standard,
and eight for sprint. The scripted trader supplies proposals. All four messages
are frozen before a turn resolves. The exporter records successful offers,
signings, and transfers from actual engine events, separately from proposals.
Rejected or normalized operations are not admitted as successful teacher labels.

Private `trajectories.jsonl`, `execution.jsonl`, and `manifest.json` files retain
source revision, exact prompts, hashes, resolved actions, event intervals, and scores.
Teacher rows have no inference requests, platform call IDs, or behavior log probabilities.
These are candidates: convert with Coworld's `export_complete_episodes`, then use
Metta's independent source-hash review gate before exporting training labels.
Keep each `escrow-SEED` family together across variants and wordings. No automatic
train/validation files are emitted. At least ten games are required; existing
output directories are never overwritten. Held-out wording exports are rejected.

## Native evidence and checks

Optional `ESCROW_HOST_TRACE_PATH` and `ESCROW_ATTEMPT_TRACE_DIR` record private
host decisions and actual model attempts. Set `ESCROW_SOURCE_REVISION` to the
qualified source revision. Records preserve exact request bodies, retry messages,
hashes, failures, parsed proposals, resolved actions, and replay event intervals.
Do not publish these evidence files as replay artifacts.

```sh
python3 tools/test_train_bridge.py /tmp/escrow-train-bridge
python3 tools/test_prompt_games.py /tmp/escrow-train-bridge /tmp/original-escrow-bridge
python3 tools/test_export_posttrain.py /tmp/escrow-export
python3 tools/test_native_prompts.py /tmp/escrow-game /tmp/escrow-player /tmp/escrow-native
```

The prompt panel runs 50 complete text games and four original numeric comparisons.
The export panel checks 20 games against resolved events. The native panel runs
nine published games with real host/player processes and a reserved closed inference
endpoint; `--smoke` runs both canonical variants. These checks establish execution
and invariants, not successful provider inference or improved learning.
