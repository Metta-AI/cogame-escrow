## Pure game rules for Escrow. No IO, no networking, no LLM — the server,
## the tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded seat→profile deal and the
## aliases, the four booths, the escrow board, the live turn's decisions,
## each seat's private notes, and the append-only event log. Everything
## random is drawn from the seed at `initSim`, so a replay re-derives the
## whole episode from the recorded `move` events alone.

import std/[json, random, strutils, unicode], dsl

export dsl

const
  MinTurns* = 4
  MaxTurns* = 40
  MaxFills* = 2
    ## Copies of its commission a seat may fill per turn.
  MaxGives* = 2
  MaxSigns* = 2
  MaxSayLen* = 160
  MaxNotesLen* = 600
  StartStock* = 3
  StartHearts* = 20
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 120_000
  ## Turns of settled/expired history the floor keeps visible.
  RecentTurns* = 3
  ProfileNames* = ["Mason", "Farmer", "Forester", "Factor"]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## Comparative advantage, drawn straight from the tables: a Mason's own
  ## 6 ore a turn is worthless to its own commission and is exactly what
  ## the Farmer and the Forester need.
  Production*: array[Profile, Bundle] = [
    pMason: [gOre: 6, gGrain: 1, gTimber: 1, gHearts: 0],
    pFarmer: [gOre: 1, gGrain: 6, gTimber: 1, gHearts: 0],
    pForester: [gOre: 1, gGrain: 1, gTimber: 6, gHearts: 0],
    pFactor: [gOre: 2, gGrain: 2, gTimber: 2, gHearts: 0]
  ]
  Commission*: array[Profile, Bundle] = [
    pMason: [gOre: 0, gGrain: 2, gTimber: 2, gHearts: 0],
    pFarmer: [gOre: 2, gGrain: 0, gTimber: 2, gHearts: 0],
    pForester: [gOre: 2, gGrain: 2, gTimber: 0, gHearts: 0],
    pFactor: [gOre: 2, gGrain: 2, gTimber: 2, gHearts: 0]
  ]
  CommissionPay*: array[Profile, int] = [
    pMason: 10, pFarmer: 10, pForester: 10, pFactor: 12
  ]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the floor: every seat trades under
  ## an anonymous cog name, drawn deterministically from the seed so
  ## replays and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the turn count into the episode's limits. Idempotent: a config
  ## that already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.turns = max(min(config.turns, MaxTurns), MinTurns)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.turns, 1))
  result.sampled = true

proc clip*(text: string, limit: int): string =
  ## Cut on a RUNE boundary: a byte slice through a multi-byte character
  ## would leave invalid UTF-8 in the replay and break its JSON.
  result = text.strip()
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, turn: -1, seat: -1, target: -1, n: 0, due: -1,
    ok: true, good: gOre, thenPay: poKeep, elsePay: poKeep, payout: poKeep)

proc logTurn(sim: var Sim) =
  var event = blankEvent(evTurn)
  event.turn = sim.turn
  for seat in 0 ..< Seats:
    event.seats.add(sim.seats[seat])
  for contract in sim.contracts:
    if contract.status in {csOffered, csSigned}:
      event.board.add(contract)
  sim.addEvent(event)

proc openTurn(sim: var Sim) =
  ## Step 1 of the turn: production. Then the floor is snapshotted and the
  ## seats decide against exactly this state.
  for seat in 0 ..< Seats:
    let profile = sim.profileOf[seat]
    for good in Good:
      sim.seats[seat].stock[good] += Production[profile][good]
    sim.moves[seat] = Move()
    sim.moveIn[seat] = false
  sim.heard = sim.says
  sim.says = ["", "", "", ""]
  var record: TurnRecord
  record.seats = sim.seats
  sim.history.add(record)
  sim.phase = phMoves
  sim.logTurn()

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(EscrowError,
      "escrow needs exactly " & $Seats & " players")
  if config.turns < MinTurns:
    raise newException(EscrowError, "turns must be at least " & $MinTurns)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides: the profile deal. No slot
  ## is structurally stuck with one role.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var deal = @[0, 1, 2, 3]
  rng.shuffle(deal)
  for seat in 0 ..< Seats:
    let profile = Profile(deal[seat])
    result.profileOf[seat] = profile
    result.seatOfProfile[profile] = seat
    result.seats[seat].stock[gOre] = StartStock
    result.seats[seat].stock[gGrain] = StartStock
    result.seats[seat].stock[gTimber] = StartStock
    result.seats[seat].stock[gHearts] = StartHearts
  result.notes = newSeq[string](Seats)
  result.nextId = 1
  result.turn = 0
  result.addEvent(blankEvent(evStart))
  result.openTurn()

# ---- Queries ----------------------------------------------------------------

proc profileName*(sim: Sim, seat: int): string =
  $sim.profileOf[seat]

proc pendingSeats*(sim: Sim): seq[int] =
  ## The seats whose decision for the live turn is still due, in seat
  ## order. Empty once the episode is over.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if not sim.moveIn[seat]:
      result.add(seat)

proc hearts*(sim: Sim, seat: int): int =
  sim.seats[seat].stock[gHearts]

proc score*(sim: Sim, seat: int): int =
  ## Free hearts after the horizon closure. HIGHER IS BETTER. Leftover
  ## goods are worth nothing, so the last turns are a scramble to convert.
  sim.seats[seat].stock[gHearts]

proc heartsMinted*(sim: Sim): int =
  for seat in 0 ..< Seats:
    result += sim.seats[seat].heartsEarned

proc canPay*(sim: Sim, seat: int, bundle: Bundle): bool =
  for good in Good:
    if sim.seats[seat].stock[good] < bundle[good]:
      return false
  true

proc contractIndex*(sim: Sim, id: string): int =
  for index, contract in sim.contracts:
    if contract.id == id:
      return index
  -1

# ---- Escrow plumbing --------------------------------------------------------

proc lockInto(sim: var Sim, seat: int, bundle: Bundle) =
  for good in Good:
    sim.seats[seat].stock[good] -= bundle[good]
    sim.seats[seat].escrowed[good] += bundle[good]

proc releaseFrom(sim: var Sim, seat: int, bundle: Bundle) =
  for good in Good:
    sim.seats[seat].escrowed[good] -= bundle[good]

proc payTo(sim: var Sim, seat: int, bundle: Bundle) =
  for good in Good:
    sim.seats[seat].stock[good] += bundle[good]

# ---- Move validation --------------------------------------------------------

proc validateMove*(sim: Sim, seat: int, move: Move): string =
  ## "" when every part of `move` is legal against the floor as it stands,
  ## walked in the sim's own resolution order (signs, gives, then the
  ## offer). This is the strict probe an LLM reply must pass before it is
  ## accepted; a reply that fails buys the seat one retry carrying exactly
  ## this text.
  if seat < 0 or seat >= Seats:
    return "bad seat"
  if move.gives.len > MaxGives:
    return "at most " & $MaxGives & " gives per turn"
  if move.signs.len > MaxSigns:
    return "at most " & $MaxSigns & " signings per turn"
  var stock = sim.seats[seat].stock
  var seen: seq[string]
  for id in move.signs:
    if id in seen:
      return "you listed " & id & " twice"
    seen.add(id)
    let index = sim.contractIndex(id)
    if index < 0:
      return "there is no contract " & id
    let contract = sim.contracts[index]
    if contract.status != csOffered:
      return id & " is not open for signature"
    if contract.acceptor != seat:
      return id & " is not addressed to you"
    for good in Good:
      stock[good] -= contract.ask[good]
      if stock[good] < 0:
        return "you cannot pay the ASK of " & id
  for give in move.gives:
    if give.to < 0 or give.to >= Seats:
      return "a give must name a cog at this table"
    if give.to == seat:
      return "you cannot give to yourself"
    if give.n < 1 or give.n > MaxUnits:
      return "a give is 1.." & $MaxUnits & " units"
    stock[give.good] -= give.n
    if stock[give.good] < 0:
      return "you cannot afford to give " & $give.n & " " & $give.good
  if move.offer.strip().len > 0:
    let parsed = parseContract(move.offer, sim, seat)
    if not parsed.ok:
      return parsed.reason & ": " & parsed.message
    for good in Good:
      stock[good] -= parsed.contract.lock[good]
      if stock[good] < 0:
        return "unfunded: you cannot lock " & renderBundle(parsed.contract.lock) &
          " after this turn's other actions"
  ""

# ---- Resolution -------------------------------------------------------------

proc applySign(sim: var Sim, seat: int, id: string) =
  var event = blankEvent(evSign)
  event.turn = sim.turn
  event.seat = seat
  event.id = id
  let index = sim.contractIndex(id)
  if index < 0:
    event.ok = false
    event.text = "there is no contract " & id
  elif sim.contracts[index].status != csOffered:
    event.ok = false
    event.text = id & " is not open for signature"
  elif sim.contracts[index].acceptor != seat:
    event.ok = false
    event.text = id & " is not addressed to you"
  elif sim.contracts[index].postedTurn != sim.turn - 1:
    event.ok = false
    event.text = id & " cannot be signed this turn"
  elif not sim.canPay(seat, sim.contracts[index].ask):
    event.ok = false
    event.text = "you cannot pay the ASK of " & id
  else:
    sim.lockInto(seat, sim.contracts[index].ask)
    sim.contracts[index].status = csSigned
    sim.contracts[index].signedTurn = sim.turn
    inc sim.seats[seat].signedCount
    inc sim.seats[sim.contracts[index].proposer].signedCount
    event.target = sim.contracts[index].proposer
  sim.addEvent(event)

proc applyGive(sim: var Sim, seat: int, give: GiveOrder) =
  var event = blankEvent(evGive)
  event.turn = sim.turn
  event.seat = seat
  event.target = give.to
  event.n = give.n
  event.good = give.good
  if give.to < 0 or give.to >= Seats or give.to == seat:
    event.ok = false
    event.text = "a give must name another cog at this table"
  elif give.n < 1 or give.n > MaxUnits:
    event.ok = false
    event.text = "a give is 1.." & $MaxUnits & " units"
  elif sim.seats[seat].stock[give.good] < give.n:
    event.ok = false
    event.text = "you hold only " & $sim.seats[seat].stock[give.good] &
      " free " & $give.good
  else:
    sim.seats[seat].stock[give.good] -= give.n
    sim.seats[give.to].stock[give.good] += give.n
    sim.transfers.add(Transfer(turn: sim.turn, sender: seat,
      receiver: give.to, good: give.good, n: give.n))
  sim.addEvent(event)

proc applyOffer(sim: var Sim, seat: int, text: string) =
  let parsed = parseContract(text, sim, seat)
  if not parsed.ok:
    var event = blankEvent(evReject)
    event.turn = sim.turn
    event.seat = seat
    event.text = parsed.reason & ": " & parsed.message
    sim.addEvent(event)
    return
  var contract = parsed.contract
  contract.id = "C" & $sim.nextId
  inc sim.nextId
  ## An offer on the board is ALWAYS funded: the stake leaves free stock
  ## the moment the contract is posted.
  sim.lockInto(seat, contract.lock)
  sim.contracts.add(contract)
  var event = blankEvent(evOffer)
  event.turn = sim.turn
  event.seat = seat
  event.target = contract.acceptor
  event.id = contract.id
  event.dsl = contract.text
  event.lock = contract.lock
  event.ask = contract.ask
  event.due = contract.due
  event.cond = renderCondition(sim, contract.cond)
  event.thenPay = contract.thenPay
  event.elsePay = contract.elsePay
  sim.addEvent(event)

proc expireContract(sim: var Sim, index: int) =
  let contract = sim.contracts[index]
  sim.releaseFrom(contract.proposer, contract.lock)
  sim.payTo(contract.proposer, contract.lock)
  sim.contracts[index].status = csExpired
  var event = blankEvent(evExpire)
  event.turn = sim.turn
  event.id = contract.id
  event.seat = contract.proposer
  sim.addEvent(event)

proc settleContract(sim: var Sim, index: int, horizon = false) =
  ## Nothing can be paid that is not already in escrow. Settlement only
  ## redistributes the two locked bundles, which is what makes breach
  ## impossible: non-performance is the ELSE branch firing, not a refusal.
  let contract = sim.contracts[index]
  var held = false
  var payout = poKeep
  var branch = "horizon"
  if not horizon:
    held = sim.evalCondition(contract)
    payout = if held: contract.thenPay else: contract.elsePay
    branch = if held: "then" else: "else"
  sim.releaseFrom(contract.proposer, contract.lock)
  sim.releaseFrom(contract.acceptor, contract.ask)
  var toProposer: Bundle
  var toAcceptor: Bundle
  case payout
  of poSwap:
    toProposer = contract.ask
    toAcceptor = contract.lock
  of poKeep:
    toProposer = contract.lock
    toAcceptor = contract.ask
  of poProposer:
    for good in Good:
      toProposer[good] = contract.lock[good] + contract.ask[good]
  of poAcceptor:
    for good in Good:
      toAcceptor[good] = contract.lock[good] + contract.ask[good]
  sim.payTo(contract.proposer, toProposer)
  sim.payTo(contract.acceptor, toAcceptor)
  if payout == poProposer:
    inc sim.seats[contract.acceptor].forfeits
  elif payout == poAcceptor:
    inc sim.seats[contract.proposer].forfeits
  sim.contracts[index].status = csSettled
  var event = blankEvent(evSettle)
  event.turn = sim.turn
  event.id = contract.id
  event.seat = contract.proposer
  event.target = contract.acceptor
  event.cond = renderCondition(sim, contract.cond)
  event.held = held
  event.branch = branch
  event.payout = payout
  for good in Good:
    if toProposer[good] > 0:
      event.legs.add(PayoutLeg(to: contract.proposer, n: toProposer[good],
        good: good))
    if toAcceptor[good] > 0:
      event.legs.add(PayoutLeg(to: contract.acceptor, n: toAcceptor[good],
        good: good))
  sim.addEvent(event)

proc fillCommissions(sim: var Sim, seat: int) =
  ## The ONLY source of new hearts in the game. Everything else is a
  ## transfer between seats and is zero-sum.
  let profile = sim.profileOf[seat]
  var filled = 0
  var earned = 0
  for copy in 0 ..< MaxFills:
    if not sim.canPay(seat, Commission[profile]):
      break
    for good in Good:
      sim.seats[seat].stock[good] -= Commission[profile][good]
    sim.seats[seat].stock[gHearts] += CommissionPay[profile]
    earned += CommissionPay[profile]
    inc filled
  if filled == 0:
    return
  sim.seats[seat].fills += filled
  sim.seats[seat].heartsEarned += earned
  var event = blankEvent(evFill)
  event.turn = sim.turn
  event.seat = seat
  event.n = filled
  event.hearts = earned
  sim.addEvent(event)

proc closeHorizon(sim: var Sim) =
  ## Nothing is stranded, so "hearts at the end" is unambiguous: every
  ## offer refunds its proposer and every signed contract closes as KEEP.
  for index in 0 ..< sim.contracts.len:
    if sim.contracts[index].status == csOffered:
      sim.expireContract(index)
  for index in 0 ..< sim.contracts.len:
    if sim.contracts[index].status == csSigned:
      sim.settleContract(index, horizon = true)

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.turn = sim.turnsPlayed
  event.text = reason
  sim.addEvent(event)

proc resolveTurn(sim: var Sim) =
  ## Steps 3..9, in exactly this order.
  let now = sim.turn
  for seat in 0 ..< Seats:
    for id in sim.moves[seat].signs:
      sim.applySign(seat, id)
  for seat in 0 ..< Seats:
    for give in sim.moves[seat].gives:
      sim.applyGive(seat, give)
  for seat in 0 ..< Seats:
    if sim.moves[seat].offer.strip().len > 0:
      sim.applyOffer(seat, sim.moves[seat].offer)
  ## An offer lives exactly one turn: posted on t, signable only on t+1.
  for index in 0 ..< sim.contracts.len:
    if sim.contracts[index].status == csOffered and
        sim.contracts[index].postedTurn == now - 1:
      sim.expireContract(index)
  ## Contracts are appended in id order, so this is ascending id.
  for index in 0 ..< sim.contracts.len:
    if sim.contracts[index].status == csSigned and
        sim.contracts[index].due == now:
      sim.settleContract(index)
  for seat in 0 ..< Seats:
    sim.fillCommissions(seat)
  sim.history[^1].moves = sim.moves
  inc sim.turnsPlayed
  inc sim.turn
  if sim.turnsPlayed >= sim.config.turns:
    sim.closeHorizon()
    sim.settle("complete")
  else:
    sim.openTurn()

proc applyMove*(sim: var Sim, seat: int, move: Move, scripted: bool) =
  ## Records `seat`'s decision for the live turn. Illegal PARTS of a
  ## decision are not fatal here — they are rejected and logged when the
  ## turn resolves — but a seat that has already decided, an unknown seat,
  ## or a finished episode raises. The fourth move resolves the turn.
  if sim.done:
    raise newException(EscrowError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(EscrowError, "bad seat: " & $seat)
  if sim.moveIn[seat]:
    raise newException(EscrowError,
      sim.names[seat] & " has already decided this turn")
  var decision = move
  if decision.gives.len > MaxGives:
    decision.gives.setLen(MaxGives)
  if decision.signs.len > MaxSigns:
    decision.signs.setLen(MaxSigns)
  decision.offer = clip(decision.offer, MaxOfferChars)
  var message = decision.say.replace("\n", " ")
  if not sim.config.talk:
    message = ""
  decision.say = clip(message, MaxSayLen)
  decision.notes = clip(decision.notes, MaxNotesLen)
  sim.moves[seat] = decision
  sim.moveIn[seat] = true
  sim.says[seat] = decision.say
  if decision.notes.len > 0:
    sim.notes[seat] = decision.notes
  var event = blankEvent(evMove)
  event.turn = sim.turn
  event.seat = seat
  event.scripted = scripted
  event.offer = decision.offer
  event.gives = decision.gives
  event.signs = decision.signs
  event.say = decision.say
  event.text = sim.notes[seat]
  sim.addEvent(event)
  if sim.pendingSeats().len == 0:
    sim.resolveTurn()

proc endEarly*(sim: var Sim) =
  ## Stop now, between turns. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest episode
  ## always beats a long one that never lands. The horizon closure runs
  ## first, so no escrow is stranded.
  if sim.done:
    return
  sim.closeHorizon()
  sim.settle("deadline")

# ---- JSON -------------------------------------------------------------------

proc bundleJson*(bundle: Bundle): JsonNode =
  ## Only the goods that are actually in the bundle.
  result = newJObject()
  for good in Good:
    if bundle[good] != 0:
      result[$good] = %bundle[good]

proc bundleFromJson*(node: JsonNode): Bundle =
  if node.isNil or node.kind != JObject:
    return
  for good in Good:
    result[good] = node{$good}.getInt(0)

proc fullBundleJson(bundle: Bundle): JsonNode =
  result = newJObject()
  for good in Good:
    result[$good] = %bundle[good]

proc seatStateJson*(state: SeatState): JsonNode =
  %*{
    "stock": fullBundleJson(state.stock),
    "escrowed": fullBundleJson(state.escrowed),
    "fills": state.fills,
    "heartsEarned": state.heartsEarned,
    "signed": state.signedCount,
    "forfeits": state.forfeits
  }

proc seatStateFromJson*(node: JsonNode): SeatState =
  result = SeatState(
    stock: bundleFromJson(node{"stock"}),
    escrowed: bundleFromJson(node{"escrowed"}),
    fills: node{"fills"}.getInt(),
    heartsEarned: node{"heartsEarned"}.getInt(),
    signedCount: node{"signed"}.getInt(),
    forfeits: node{"forfeits"}.getInt()
  )

proc conditionJson(cond: Condition): JsonNode =
  %*{
    "kind": $cond.kind,
    "not": cond.negated,
    "who": cond.who,
    "n": cond.n,
    "good": $cond.good
  }

proc conditionFromJson(node: JsonNode): Condition =
  if node.isNil or node.kind != JObject:
    return Condition(kind: ckAlways, who: -1)
  Condition(
    kind: parseEnum[CondKind](node{"kind"}.getStr("ALWAYS")),
    negated: node{"not"}.getBool(),
    who: node{"who"}.getInt(-1),
    n: node{"n"}.getInt(),
    good: parseEnum[Good](node{"good"}.getStr("ORE"))
  )

proc contractJson*(contract: Contract): JsonNode =
  %*{
    "id": contract.id,
    "proposer": contract.proposer,
    "acceptor": contract.acceptor,
    "lock": bundleJson(contract.lock),
    "ask": bundleJson(contract.ask),
    "due": contract.due,
    "cond": conditionJson(contract.cond),
    "then": $contract.thenPay,
    "else": $contract.elsePay,
    "status": $contract.status,
    "postedTurn": contract.postedTurn,
    "signedTurn": contract.signedTurn,
    "dsl": contract.text
  }

proc contractFromJson*(node: JsonNode): Contract =
  Contract(
    id: node{"id"}.getStr(),
    proposer: node{"proposer"}.getInt(-1),
    acceptor: node{"acceptor"}.getInt(-1),
    lock: bundleFromJson(node{"lock"}),
    ask: bundleFromJson(node{"ask"}),
    due: node{"due"}.getInt(-1),
    cond: conditionFromJson(node{"cond"}),
    thenPay: parseEnum[Payout](node{"then"}.getStr("KEEP")),
    elsePay: parseEnum[Payout](node{"else"}.getStr("KEEP")),
    status: parseEnum[ContractStatus](node{"status"}.getStr("offered")),
    postedTurn: node{"postedTurn"}.getInt(-1),
    signedTurn: node{"signedTurn"}.getInt(-1),
    text: node{"dsl"}.getStr()
  )

proc givesJson(gives: seq[GiveOrder]): JsonNode =
  result = newJArray()
  for give in gives:
    result.add(%*{"to": give.to, "n": give.n, "good": $give.good})

proc givesFromJson(node: JsonNode): seq[GiveOrder] =
  if node.isNil or node.kind != JArray:
    return
  for entry in node:
    result.add(GiveOrder(
      to: entry{"to"}.getInt(-1),
      n: entry{"n"}.getInt(),
      good: parseEnum[Good](entry{"good"}.getStr("ORE"))
    ))

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.turn >= 0:
    result["turn"] = %event.turn
  case event.kind
  of evStart:
    discard
  of evTurn:
    var seats = newJArray()
    for state in event.seats:
      seats.add(seatStateJson(state))
    result["seats"] = seats
    var board = newJArray()
    for contract in event.board:
      board.add(contractJson(contract))
    result["board"] = board
  of evMove:
    result["seat"] = %event.seat
    result["scripted"] = %event.scripted
    if event.offer.len > 0:
      result["offer"] = %event.offer
    if event.gives.len > 0:
      result["gives"] = givesJson(event.gives)
    if event.signs.len > 0:
      var signs = newJArray()
      for id in event.signs:
        signs.add(%id)
      result["signs"] = signs
    if event.say.len > 0:
      result["say"] = %event.say
  of evOffer:
    result["seat"] = %event.seat
    result["target"] = %event.target
    result["id"] = %event.id
    result["dsl"] = %event.dsl
    result["lock"] = bundleJson(event.lock)
    result["ask"] = bundleJson(event.ask)
    result["due"] = %event.due
    result["cond"] = %event.cond
    result["then"] = %($event.thenPay)
    result["else"] = %($event.elsePay)
  of evSign:
    result["seat"] = %event.seat
    result["id"] = %event.id
    result["ok"] = %event.ok
  of evGive:
    result["seat"] = %event.seat
    result["to"] = %event.target
    result["n"] = %event.n
    result["good"] = %($event.good)
    result["ok"] = %event.ok
  of evReject:
    result["seat"] = %event.seat
  of evExpire:
    result["id"] = %event.id
    result["seat"] = %event.seat
  of evSettle:
    result["id"] = %event.id
    result["seat"] = %event.seat
    result["target"] = %event.target
    result["cond"] = %event.cond
    result["held"] = %event.held
    result["branch"] = %event.branch
    result["payout"] = %($event.payout)
    var legs = newJArray()
    for leg in event.legs:
      legs.add(%*{"to": leg.to, "n": leg.n, "good": $leg.good})
    result["transfers"] = legs
  of evFill:
    result["seat"] = %event.seat
    result["n"] = %event.n
    result["hearts"] = %event.hearts
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    turn: node{"turn"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    scripted: node{"scripted"}.getBool(false),
    ok: node{"ok"}.getBool(true),
    text: node{"text"}.getStr(""),
    say: node{"say"}.getStr(""),
    offer: node{"offer"}.getStr(""),
    gives: givesFromJson(node{"gives"}),
    id: node{"id"}.getStr(""),
    target: node{"target"}.getInt(node{"to"}.getInt(-1)),
    n: node{"n"}.getInt(0),
    good: parseEnum[Good](node{"good"}.getStr("ORE")),
    dsl: node{"dsl"}.getStr(""),
    lock: bundleFromJson(node{"lock"}),
    ask: bundleFromJson(node{"ask"}),
    due: node{"due"}.getInt(-1),
    cond: node{"cond"}.getStr(""),
    thenPay: parseEnum[Payout](node{"then"}.getStr("KEEP")),
    elsePay: parseEnum[Payout](node{"else"}.getStr("KEEP")),
    held: node{"held"}.getBool(false),
    branch: node{"branch"}.getStr(""),
    payout: parseEnum[Payout](node{"payout"}.getStr("KEEP")),
    hearts: node{"hearts"}.getInt(0)
  )
  if node.hasKey("signs"):
    for id in node["signs"]:
      result.signs.add(id.getStr())
  if node.hasKey("transfers"):
    for leg in node["transfers"]:
      result.legs.add(PayoutLeg(
        to: leg{"to"}.getInt(-1),
        n: leg{"n"}.getInt(),
        good: parseEnum[Good](leg{"good"}.getStr("ORE"))
      ))
  if node.hasKey("seats"):
    for state in node["seats"]:
      result.seats.add(seatStateFromJson(state))
  if node.hasKey("board"):
    for contract in node["board"]:
      result.board.add(contractFromJson(contract))

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var heartsNode = newJArray()
  var fills = newJArray()
  var signed = newJArray()
  var forfeits = newJArray()
  var profiles = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat traded under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    heartsNode.add(%sim.hearts(seat))
    fills.add(%sim.seats[seat].fills)
    signed.add(%sim.seats[seat].signedCount)
    forfeits.add(%sim.seats[seat].forfeits)
    profiles.add(%sim.profileName(seat))
  %*{
    "names": names,
    "scores": scores,
    "hearts": heartsNode,
    "fills": fills,
    "signed": signed,
    "forfeits": forfeits,
    "profiles": profiles,
    "turns": sim.turnsPlayed,
    "maxTurns": sim.config.turns,
    "heartsMinted": sim.heartsMinted(),
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc boardJson*(sim: Sim): JsonNode =
  result = newJArray()
  for contract in sim.contracts:
    if contract.status notin {csOffered, csSigned}:
      continue
    result.add(%*{
      "id": contract.id,
      "proposer": contract.proposer,
      "acceptor": contract.acceptor,
      "status": $contract.status,
      "lock": bundleJson(contract.lock),
      "ask": bundleJson(contract.ask),
      "due": contract.due,
      "turnsLeft": contract.due - sim.turn,
      "cond": renderCondition(sim, contract.cond),
      "then": $contract.thenPay,
      "else": $contract.elsePay,
      "dsl": contract.text
    })

proc recentJson*(sim: Sim): JsonNode =
  ## Settlements and expiries from the last few turns, so a spectator (and
  ## a seat) can see how the last clauses actually landed.
  result = newJArray()
  for event in sim.events:
    if event.turn < sim.turn - RecentTurns:
      continue
    case event.kind
    of evSettle:
      var legs = newJArray()
      for leg in event.legs:
        legs.add(%*{"to": leg.to, "n": leg.n, "good": $leg.good})
      result.add(%*{
        "id": event.id,
        "turn": event.turn,
        "held": event.held,
        "branch": event.branch,
        "payout": $event.payout,
        "cond": event.cond,
        "transfers": legs
      })
    of evExpire:
      result.add(%*{
        "id": event.id,
        "turn": event.turn,
        "held": false,
        "branch": "expired",
        "payout": "KEEP",
        "cond": "",
        "transfers": newJArray()
      })
    else:
      discard

proc tableStateJson*(sim: Sim): JsonNode =
  ## One frame; the viewer draws exactly this.
  let pending = sim.pendingSeats()
  var seats = newJArray()
  var heartsNode = newJArray()
  for seat in 0 ..< Seats:
    let profile = sim.profileOf[seat]
    var heard = newJArray()
    for other in 0 ..< Seats:
      if other != seat and sim.heard[other].len > 0:
        heard.add(%*{"seat": other, "say": sim.heard[other]})
    seats.add(%*{
      "name": sim.names[seat],
      "profile": $profile,
      "score": sim.score(seat),
      "hearts": sim.hearts(seat),
      "stock": fullBundleJson(sim.seats[seat].stock),
      "escrowed": fullBundleJson(sim.seats[seat].escrowed),
      "production": bundleJson(Production[profile]),
      "commission": bundleJson(Commission[profile]),
      "commissionPay": CommissionPay[profile],
      "fills": sim.seats[seat].fills,
      "signed": sim.seats[seat].signedCount,
      "forfeits": sim.seats[seat].forfeits,
      "say": sim.says[seat],
      "heard": heard,
      "notes": sim.notes[seat],
      "pending": seat in pending
    })
    heartsNode.add(%sim.hearts(seat))
  %*{
    "seats": seats,
    "board": sim.boardJson(),
    "recent": sim.recentJson(),
    "hearts": heartsNode,
    "turn": sim.turn,
    "turns": sim.config.turns,
    "turnsPlayed": sim.turnsPlayed,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc sameSeats(a: seq[SeatState], b: array[Seats, SeatState]): bool =
  if a.len != b.len:
    return false
  for index in 0 ..< a.len:
    if a[index].stock != b[index].stock or
        a[index].escrowed != b[index].escrowed or
        a[index].fills != b[index].fills or
        a[index].heartsEarned != b[index].heartsEarned or
        a[index].signedCount != b[index].signedCount or
        a[index].forfeits != b[index].forfeits:
      return false
  true

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the MOVE events through the rules (profiles and aliases come from the
  ## seed). Everything else in the log is derived by the rules and merely
  ## checked. frames[i] = state after events[0..<i].
  var sim = initSim(config)
  ## initSim already logged the start and the first turn event; the
  ## recorded log opens with those same two.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evTurn:
      if event.turn != sim.turn or not sameSeats(event.seats, sim.seats):
        raise newException(EscrowError,
          "turn " & $event.turn & " does not match the seeded re-derivation")
      if sim.events.len == 0 or sim.events[^1].kind != evTurn:
        sim.events.add(event)
    of evMove:
      sim.applyMove(event.seat, Move(
        offer: event.offer,
        gives: event.gives,
        signs: event.signs,
        say: event.say,
        notes: event.text
      ), event.scripted)
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the moves alone.
        sim.closeHorizon()
        sim.settle(event.text)
    else:
      ## Derived by the rules; the re-derivation already produced it.
      discard
    result.add(sim)
