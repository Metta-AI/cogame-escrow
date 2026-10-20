# Prompt variants and training

The default `canonical` prompt preserves the original messages. Five training
wordings (`canonical`, `plain`, `numbered`, `questions`, `reordered`) paraphrase
identity, production/scoring, and pre-funded contracts in the v2 bank.
Contract syntax, examples, strategic hints, game facts, and budgets stay fixed.
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

## Teacher exports

Build once and export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/escrow-export tools/export_posttrain.nim
/tmp/escrow-export /tmp/escrow-standard 10 1 standard mixed 0
/tmp/escrow-export /tmp/escrow-sprint 10 1 sprint mixed 0
```

Each export runs complete published games: four players, 16 turns for standard,
and eight for sprint. The scripted trader supplies proposals. All four messages
are frozen before a turn resolves. The exporter records successful offers,
signings, and transfers from actual engine events, separately from proposals.
Rejected or normalized operations are not admitted as successful teacher labels.

The original `train.jsonl`, `validation.jsonl`, and `manifest.json` files
are preserved. Rows record wording metadata and message hashes; the manifest
pins the source revision and each game's selection. Mixed selection cycles the
five training wordings separately within each split. Episode IDs include requested selection, resolved wording, and prompt seed
to distinguish matched collections. Seed families exclude variant and wording;
multiples of five enter validation. Held-out wordings are rejected.
Output directories are private and must not already exist.

## Validation

```sh
python3 tools/test_train_bridge.py /tmp/escrow-train-bridge
python3 tools/test_prompt_games.py /tmp/escrow-train-bridge
python3 tools/test_export_posttrain.py /tmp/escrow-export
```

The wording workflow runs 20 complete games, including private-note persistence,
public speech, numeric normalization, and both published horizons.
The exporter workflow covers 20 complete games, seed-family separation, and
contract/action grammar. These checks establish mechanics and protocol behavior,
not improved learning or resistance to policy collapse.
