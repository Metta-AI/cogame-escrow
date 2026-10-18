## Complete private candidates. Shared review owns admission to training.
import std/[json, os, osproc, strutils]
import escrow/[llm, sim, observations, evidence]

const OperatorPrompt = "Trade to maximize your own score using only your booth and the public floor."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "standard"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert games >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + games:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      var world = initSim(config)
      let family = "escrow-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var count = 0
      while not world.done:
        let view = world
        let seats = view.pendingSeats()
        var orders: array[Seats, Move]
        var records: array[Seats, JsonNode]
        for seat in seats:
          let system = systemPrompt(view, seat, selection)
          let user = userPrompt(view, seat, OperatorPrompt)
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          var observation = decisionView(view, seat)
          observation["prompt_template"] = selection.promptMetadata(system, user)
          let teacher = scriptedAction(view, seat, skTrader)
          let proposal = decisionJson(teacher)
          orders[seat] = parseDecision(proposal, view, seat)
          let normalized = decisionJson(orders[seat])
          let accepted = proposal == normalized
          let id = count + seat
          let attemptId = $id & "-teacher"
          let attempt = %*{
            "attempt_id": attemptId, "policy": "scripted-trader", "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages,
            "response": $proposal, "parsed_action": proposal, "accepted": accepted,
            "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
            "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")}
          records[seat] = %*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $id, "decision_index": id,
            "game": "escrow", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": observation, "prompt": (if accepted: messages else: newJNull()),
            "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
            "executed_action": normalized, "action_status": (if accepted: "accepted" else: "fallback"),
            "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
            "terminal": false}
        let eventStart = world.events.len
        for seat in seats:
          world.applyMove(seat, orders[seat], true)
        var events = newJArray()
        for index in eventStart ..< world.events.len: events.add(eventToJson(world.events[index]))
        for seat in seats:
          let executed = decisionJson(world.resolvedMove(seat, eventStart))
          let accepted = executed == records[seat]["attempts"][0]["parsed_action"]
          records[seat]["executed_action"] = executed
          records[seat]["attempts"][0]["accepted"] = %accepted
          records[seat]["terminal"] = %(world.done and seat == seats[^1])
          if not accepted:
            records[seat]["attempts"][0]["rejection_reason"] = %"engine-normalized-submission"
            records[seat]["selected_attempt_id"] = newJNull()
            records[seat]["prompt"] = newJNull()
            records[seat]["action_status"] = %"fallback"
            records[seat]["fallback_origin"] = %"engine-normalized-submission"
          execution.writeLine($(%*{
            "schema_version": 1, "event_type": "decision_execution", "episode_id": episode,
            "decision_id": records[seat]["decision_id"], "source_revision": revision,
            "visibility": "private", "seat": seat, "turn": view.turn,
            "event_start": eventStart, "event_end": world.events.len, "events": events,
            "stored_notes": world.notes[seat], "resolved_action": executed,
            "terminal": world.done and seat == seats[^1]}))
          stream.writeLine($records[seat])
        count += seats.len
      doAssert world.reason == "complete"
      let outcome = world.resultsJson()
      var participants = newJObject()
      for seat in 0 ..< Seats: participants[$seat] = %*{"score": outcome["scores"][seat]}
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "escrow", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": outcome,
        "participant_outcomes": participants}))
      runs.add(%*{"seed": seed, "decisions": count, "scores": outcome["scores"], "turns_played": world.turnsPlayed})
  finally:
    execution.close()
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "escrow", "variant": variant,
    "source_revision": revision, "teacher": "scripted-trader",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete games=", games
