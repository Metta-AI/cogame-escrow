## Reconstruct actual frozen native turns, private views/prompts and complete resolution.
## No provider client, HTTP transport, scripted teacher export or synthetic completion.
import std/[json, os, strutils]
import crunchy
import escrow/[sim, llm, training_capture]
let args = commandLineParams()
doAssert args.len == 4 # CONFIG TRAJECTORY REPLAY OPERATOR_PREFIX
let configNode = parseFile(args[0])
var config = defaultGameConfig()
config.update($configNode)
config = sampleEpisode(config)
var game = initSim(config)
let selection = promptSelection(configNode)
let replay = parseFile(args[2])
var rows: seq[JsonNode]
var summary: JsonNode
for line in lines(args[1]):
  let row = parseJson(line)
  if row["event_type"].getStr() == "decision": rows.add(row)
  else: summary = row

proc playerView(sim: Sim, seat: int): JsonNode =
  let profile = sim.profileOf[seat]
  let own = sim.seats[seat]
  var stock, escrowed = newJObject()
  for good in Good:
    stock[$good] = %own.stock[good]
    escrowed[$good] = %own.escrowed[good]
  var floor = newJArray()
  for other in 0 ..< Seats:
    let role = sim.profileOf[other]
    floor.add(%*{"name": sim.names[other], "profile": $role,
      "stock": seatStateJson(sim.seats[other])["stock"],
      "escrowed": seatStateJson(sim.seats[other])["escrowed"],
      "production": bundleJson(Production[role]), "commission": bundleJson(Commission[role]),
      "commissionPay": CommissionPay[role], "hearts": sim.hearts(other)})
  %*{"type":"state", "slot":seat, "name":sim.names[seat],
    "seat":{"profile": $profile,"score":sim.score(seat),"hearts":sim.hearts(seat),
      "stock":stock,"escrowed":escrowed,"production":bundleJson(Production[profile]),
      "commission":bundleJson(Commission[profile]),"commissionPay":CommissionPay[profile],"fills":own.fills},
    "turn":sim.turn,"turns":config.turns,"turnsPlayed":sim.turnsPlayed,
    "board":sim.boardJson(),"publicSeats":floor,"recent":sim.recentJson(),
    "started":true,"done":sim.done,"reason":sim.reason}

proc numericAction(event: GameEvent, notes: string): JsonNode =
  var gives = newJArray()
  for order in event.gives: gives.add(%*{"to":order.to,"n":order.n,"good": $order.good})
  %*{"offer":event.offer,"sign":event.signs,"give":gives,"say":event.say,"notes":notes}

var promptsChecked = 0
var batchCount = 0
var index = 0
let ids = identities(game)
while index < rows.len:
  doAssert not game.done and index + Seats <= rows.len
  let turn = game.turn
  let before = game.events.len
  var moves: array[Seats, Move]
  var scripted: array[Seats, bool]
  for seat in 0 ..< Seats:
    let row = rows[index + seat]
    for other in 0 ..< Seats:
      if other != seat:
        let foreignNote = "private-note-canary-slot-" & $other
        doAssert foreignNote notin $row["observation"] and foreignNote notin $row["executed_action"],
          "foreign private note reached actor evidence"
    doAssert row["seat"].getStr() == $seat
    doAssert row["decision_id"].getStr() == $(turn + 1) & "-" & $seat
    var view = copy(row["observation"])
    doAssert view["pre_native_sha256"].getStr() == nativeStateHash(game)
    doAssert view["scenario_family"].getStr() == ids.family
    doAssert view["task_identity"].getStr() == ids.task
    for field in ["scenario_family","task_identity","prompt_selection","pre_native_sha256","native_requests","native_execution","capture_errors"]:
      if view.hasKey(field): view.delete(field)
    doAssert view == playerView(game, seat), "private view differs at " & row["decision_id"].getStr()
    var parsed = false
    var previousError = ""
    for attemptIndex, attempt in row["attempts"].getElems():
      let request = attempt["request"]
      let system = systemPrompt(game, seat, selection)
      var user = userPrompt(game, seat, args[3] & $seat)
      if attemptIndex > 0:
        user.add("\n\nYour previous reply was invalid: " & cleanText(previousError, 300) &
          ". Respond with ONLY the requested JSON object.")
      doAssert request["system"].getStr() == system
      doAssert request["messages"] == %*[{"role":"user","content":user}]
      doAssert request["max_tokens"].getInt() == config.maxOutputTokens
      inc promptsChecked
      if attempt["response"].kind == JString:
        try:
          let move = parseDecision(extractJsonObject(attempt["response"].getStr()), game, seat)
          let problem = game.validateMove(seat, move)
          if problem.len > 0: raise newException(EscrowError, problem)
          moves[seat] = move
          parsed = true
          doAssert attemptIndex == row["attempts"].len - 1
        except CatchableError as error:
          doAssert attempt["rejection_reason"].getStr() == error.msg
      if attempt["rejection_reason"].kind == JString:
        previousError = attempt["rejection_reason"].getStr()
    scripted[seat] = not parsed
    if not parsed: moves[seat] = scriptedAction(game, seat, skTrader)
  # All requests and proposals above use exactly the same pre-application native state.
  for seat in 0 ..< Seats: game.applyMove(seat, moves[seat], scripted[seat])
  var events = newJArray()
  for event in game.events[before ..< game.events.len]:
    var publicFields = event.eventToJson()
    if event.kind == evMove and publicFields.hasKey("text"): publicFields.delete("text")
    events.add(publicFields)
  for seat in 0 ..< Seats:
    let row = rows[index + seat]
    let execution = row["observation"]["native_execution"]
    doAssert execution["events"] == events
    doAssert execution["events_sha256"].getStr() == sha256($events).toHex.toLowerAscii()
    doAssert execution["post_native_sha256"].getStr() == nativeStateHash(game)
    var found = 0
    var installed: GameEvent
    for event in game.events[before ..< game.events.len]:
      if event.kind == evMove and event.seat == seat and event.turn == turn:
        installed = event
        inc found
    doAssert found == 1 and installed.scripted == scripted[seat]
    doAssert execution["notes_after"].getStr() == installed.text
    let numeric = numericAction(installed, game.history[turn].moves[seat].notes)
    doAssert execution["installed_action"] == numeric
    var projected = copy(numeric)
    for n, order in installed.gives:
      let to = row["executed_action"]["give"][n]["to"]
      if to.kind == JString:
        doAssert to.getStr() == game.names[order.to]
        projected["give"][n]["to"] = %game.names[order.to]
      else: doAssert to.kind == JInt and to.getInt() == order.to
    doAssert projected == row["executed_action"]
    doAssert projected == execution["typed_action_projection"]
  index += Seats
  inc batchCount
if not game.done:
  doAssert replay["results"]["reason"].getStr() == "deadline"
  game.endEarly()
var events = newJArray()
for event in game.events: events.add(event.eventToJson())
doAssert events == replay["events"], "complete public native replay differs"
let outcome = game.resultsJson()
var privateOutcome = copy(summary["outcome"])
if privateOutcome.hasKey("capture_errors"):
  doAssert summary["status"].getStr() == "failed"
  privateOutcome.delete("capture_errors")
doAssert outcome == privateOutcome and outcome == replay["results"]
doAssert summary["seed_family"].getStr() == ids.family
var same = config
same.turns = if config.turns == 16: 8 else: 16
let sameGame = initSim(same)
doAssert identities(sameGame).family == ids.family and identities(sameGame).task != ids.task
same = config
same.model = "unused-local-alias"
inc same.turnDelayMs
for seat in 0 ..< Seats: same.players[seat].name = "changed-policy-display-" & $seat
doAssert identities(initSim(same)) == ids
echo pretty(%*{"complete_episode":game.reason=="complete","native_reason":game.reason,
  "turns":game.turnsPlayed,"decisions":rows.len,"batches":batchCount,
  "actual_native_prompt_requests":promptsChecked,"every_private_view_request_applied_move_fullresolution_replay_outcome_verified":true,
  "family":ids.family,"task":ids.task,"horizon_model_display_timing_family_grouping_verified":true,
  "qualification":"24fixedrules/profile-priority strata, not independent worlds or strategic/teacher/learning evidence",
  "real_provider_calls":0})
