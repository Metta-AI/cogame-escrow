# Prompt variants and training

The default `canonical` prompt preserves the original messages. Five training wordings (`canonical`, `plain`,
`numbered`, `questions`, `reordered`) paraphrase identity, production/scoring, and pre-funded contracts in the v2 bank.
Contract syntax, examples, strategic hints, game facts, and budgets stay fixed. `mixed` resolves using an explicit
nonnegative `promptSeed % 5`, independently of the simulator seed. Selection stays fixed throughout an episode.
`heldout-briefing` and `heldout-reference` are evaluation-only.

## Complete text actions

The bridge accepts an optional third argument, `text`. It supports the full contract language, gives, signatures, public
speech, and private notes through the production parser and simulator. Its reset accepts `promptVariant`, `promptSeed`,
and `split`; held-out wordings cannot be used for training. Observations include exact message hashes and only the
acting seat's private notes. All four observations come from the same frozen turn state.

The existing 71-value numeric bridge and four scripted choices remain available. See
[numeric training](docs/TRAINING.md) for its commands and historical pilots.

## Native private capture

The ordinary game writes optional private decision evidence when `COGAME_SAVE_TRAJECTORY_URI` is set. With it unset,
dispatch skips the added observation copies, hashes, request copies, and evidence processing. A private destination
cannot equal the public results or replay destination. Capture failures remain visible in logs and the private summary
without changing native gameplay, fallback selection, results, or replay.

Each seat's observation is frozen before the original four-seat request batch. Evidence retains original HTTP request
and response bytes, safe request headers, all received response headers within the private evidence bound, call
identifiers, supplied decoder settings, usage, errors, and retries. The transport exposes whole-batch elapsed time, not
individual response latency; individual latency remains missing. Bodies are bounded to 64 KiB, headers to 16 KiB,
observations to 128 KiB, and episode evidence to 24 MiB. Overbound evidence is omitted with an explicit gap, never
truncated into an eligible label.

Actions are recorded only after all four native moves apply. The authoritative action comes from the installed move
event and completed turn history; complete public resolution events record gives, offers, signatures, failures,
settlement, expiry, and commissions. A legal installed command remains source-faithful even when simultaneous resolution
rejects its effect. No outcome filter turns such a command into a different action. Private notes stay within their
acting seat's evidence. The note command is distinct from persistent notes after the turn: an explicit empty command can
leave an earlier note intact.

The existing native spectator/replay serialization includes persistent notes on move events. Capture removes that field
from every copied move event and keeps only the acting seat's note command and `notes_after`. This repair does not
change the existing replay format or its notes visibility. The ordinary player view and prompt continue to hide other
seats' notes.

Eligibility requires a complete joined successful response and exact equality of every supplied JSON field, type, and
value against the native installed command. The original first-balanced-object extractor still accepts fences and
trailing prose; omitted defaults remain eligible. Duplicate keys, non-JSON syntax, non-finite numbers, excessive
nesting, and native normalization are excluded from targets without changing the production parser or raw completion.
Recipient integers are compared to the installed numeric seat; recipient strings must exactly equal that seat's frozen
alias. Case and whitespace repairs are excluded. The numeric installed action and typed comparison projection are both
recorded; the completion is never rewritten. Failed, scripted, fallback, or incomplete attempts do not become model
targets. Authenticated receipt admission remains a separate downstream gate; a local sentinel is never a teacher.

Capture also validates decoded strings and object keys as Unicode scalar UTF-8, including the complete request,
observation, action, diagnostics, and terminal outcome. Native gameplay can install bytes which are not valid Unicode.
Those rows retain their original evidence JSON bytes as base64 forensic evidence, with an explicit gap, no selected
attempt, no target action, and failed capture status. They are never repaired into text targets. The native parser
remains unchanged.

`scenario_family` hashes the actual profile assignment in native seat-priority order. There are only 24 such
assignments. Seeds, anonymous aliases, horizons, wordings, and policy labels do not create additional families. These
are fixed-rule role/priority strata, not independent worlds. `task_identity` separately hashes the effective economics,
action limits, resolution order, horizon, and talk rule. A prospective family holdout must keep all aliases of an
assignment together; an unseen assignment tests role/priority generalization only.

Run the real localhost HTTP/WebSocket workflow with prebuilt native binaries:

```sh
python3 tools/ci/native_capture_system.py --game /tmp/escrow \
  --player /tmp/escrow-player --variant standard --seed 15 \
  --output /tmp/escrow-native-capture
nim c -d:release --path:src -o:/tmp/check-escrow tools/check_native_capture.nim
/tmp/check-escrow /tmp/escrow-native-capture/config.json \
  /tmp/escrow-native-capture/trajectory.jsonl \
  /tmp/escrow-native-capture/replay.json local-operator-canary-
```

The workflow uses a local sentinel with no inherited provider credentials. Its `--no-capture` parity control and
`--mode rich`, `normalization`, `grammar`, `fidelity`, `retry`, `errors`, and `collision` cases exercise actual
production dispatch, parsing, application, private evidence, and public completion. The independent checker reconstructs
every native view, prompt, command, resolution, and outcome. These checks establish capture mechanics, not strategic
quality or learning.

The standard-library-only Unicode regression uses actual localhost HTTP calls, native parsing/application, and the
private writer. It stops after three of four configured turns, so it is a partial system component, not another complete
game. It keeps valid escaped Unicode actions and checks that invalid scalars, malformed UTF-8, and their persistent
effects retain exact forensic bytes with no target. Fixture call IDs have UUID syntax but are not authenticated provider
receipts. Compilation is bounded to 240 seconds and execution to 30 seconds/8 MiB:

```sh
python3 tools/ci/native_unicode_system.py \
  --nim "$HOME/.nimby/nim-2.2.4/bin/nim" \
  --nimcache /tmp/escrow-unicode-cache --output /tmp/escrow-unicode-proof
```

## Historical scripted exports

These exports preserve their original seed-label split. That split is not the physical profile-deal grouping used by
native capture and must not be treated as evidence of independent native train/validation families.

Build once and export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/escrow-export tools/export_posttrain.nim
/tmp/escrow-export /tmp/escrow-standard 10 1 standard mixed 0
/tmp/escrow-export /tmp/escrow-sprint 10 1 sprint mixed 0
```

Each export runs complete published games: four players, 16 turns for standard, and eight for sprint. The scripted
trader supplies proposals. All four messages are frozen before a turn resolves. The exporter records successful offers,
signings, and transfers from actual engine events, separately from proposals. Rejected or normalized operations are not
admitted as successful teacher labels.

The original `train.jsonl`, `validation.jsonl`, and `manifest.json` files are preserved. Rows record wording metadata
and message hashes; the manifest pins the source revision and each game's selection. Mixed selection cycles the five
training wordings separately within each split. Episode IDs include requested selection, resolved wording, and prompt
seed to distinguish matched collections. Seed families exclude variant and wording; multiples of five enter validation.
Held-out wordings are rejected. Output directories are private and must not already exist.

## Validation

```sh
python3 tools/test_train_bridge.py /tmp/escrow-train-bridge
python3 tools/test_prompt_games.py /tmp/escrow-train-bridge
python3 tools/test_export_posttrain.py /tmp/escrow-export
```

The wording workflow runs 20 complete games, including private-note persistence, public speech, numeric normalization,
and both published horizons. The exporter workflow covers 20 complete games, seed-family separation, and contract/action
grammar. These checks establish mechanics and protocol behavior, not improved learning or resistance to policy collapse.
