## Export complete native Escrow games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [standard|sprint]

import std/[json, os, osproc, strutils]
import escrow/[sim, llm]

const OperatorPrompt = "Trade to maximize your own score using only your booth and the public floor."
const Variants = ["standard", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [standard|sprint [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "standard"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit source before generating a pinned corpus"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for seed in firstSeed ..< firstSeed + games:
    var wording = selection
    let partition = ord(seed mod 5 == 0)
    if wording.variant == pvMixed:
      wording.seed += wordingCounts[partition]
    inc wordingCounts[partition]
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    config.update($runtimeConfig)
    config.seed = seed
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      let view = sim
      let seats = view.pendingSeats()
      let eventStart = sim.events.len
      var proposals: array[Seats, JsonNode]
      var records: array[Seats, string]
      for seat in seats:
        let teacher = view.scriptedAction(seat, skTrader)
        var gives = newJArray()
        for order in teacher.gives:
          gives.add(%*{"to": order.to, "n": order.n, "good": $order.good})
        let completion = %*{
          "offer": teacher.offer, "sign": teacher.signs,
          "give": gives, "say": teacher.say, "notes": teacher.notes
        }
        let parsed = parseDecision(completion, view, seat)
        doAssert parsed.offer == teacher.offer
        doAssert parsed.signs == teacher.signs
        doAssert parsed.gives == teacher.gives
        doAssert view.validateMove(seat, parsed) == ""
        proposals[seat] = completion
        let system = systemPrompt(view, seat, wording)
        let user = userPrompt(view, seat, OperatorPrompt)
        records[seat] = $(%*{
          "episode_id": "escrow-" & variant & "-" & $seed & "-" & $wording.variant & "-" &
            $wording.selectedVariant & "-" & $wording.seed,
          "seed": "escrow-" & $seed,
          "decision_id": view.turn * Seats + seat,
          "prompt": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "escrow",
          "prompt_template": wording.promptMetadata(system, user),
          "action_schema_revision": "escrow-move-v1"
        })
        sim.applyMove(seat, parsed, true)
      for seat in seats:
        var executed: Move
        for index in eventStart ..< sim.events.len:
          let event = sim.events[index]
          if event.seat != seat: continue
          case event.kind
          of evMove:
            executed.say = event.say
            executed.notes = sim.notes[seat]
          of evOffer: executed.offer = event.dsl
          of evSign:
            if event.ok: executed.signs.add(event.id)
          of evGive:
            if event.ok:
              executed.gives.add(GiveOrder(to: event.target, n: event.n, good: event.good))
          else: discard
        if decisionJson(executed) == proposals[seat]:
          rows.add(records[seat])
    doAssert rows.len > 0 and sim.reason == "complete"
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "hearts_minted": outcome["heartsMinted"],
      "prompt_selection": wording.selectionMetadata()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "escrow",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-trader",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
