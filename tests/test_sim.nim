## Pure-rules tests for Escrow: the DSL, the escrow mechanics, the four
## payouts, the conservation invariants, the endings, and the replay
## re-derivation. No IO, no LLM, no network — everything here drives
## src/escrow/{types,dsl,sim}.nim directly.

import std/[json, sets, strutils, unicode, unittest]
import escrow/sim

proc fixtureConfig(turns = 16, seed = 0, talk = true): GameConfig =
  result = defaultGameConfig()
  result.turns = turns
  result.seed = seed
  result.talk = talk
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc moveAll(sim: var Sim, moves: array[Seats, Move]) =
  ## Every pending seat submits its move; the fourth resolves the turn.
  for seat in sim.pendingSeats():
    sim.applyMove(seat, moves[seat], true)

proc passAll(sim: var Sim) =
  var moves: array[Seats, Move]
  sim.moveAll(moves)

proc lastOf(sim: Sim, kind: EventKind): GameEvent =
  var found = false
  for event in sim.events:
    if event.kind == kind:
      result = event
      found = true
  if not found:
    raise newException(EscrowError, "no " & $kind & " event in the log")

proc has(sim: Sim, kind: EventKind): bool =
  for event in sim.events:
    if event.kind == kind:
      return true
  false

proc offerText(sim: Sim, target: int, lock, ask, due, cond, thenPay,
    elsePay: string): string =
  "OFFER " & sim.names[target] & "\nLOCK " & lock & "\nASK " & ask &
    "\nDUE " & due & "\nIF " & cond & "\nTHEN " & thenPay & "\nELSE " & elsePay

# ---------------------------------------------------------------------------

suite "setup and the seed":
  test "1. profiles and aliases are seed-determined, and a seed replays":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var seen = initHashSet[Profile]()
      for seat in 0 ..< Seats:
        seen.incl(sim.profileOf[seat])
        check sim.seatOfProfile[sim.profileOf[seat]] == seat
      check seen.len == 4
      check sim.names.len == Seats
      check sim.names.toHashSet().len == Seats
    ## Different seeds really do move the Factor around.
    var factors = initHashSet[int]()
    for seed in 0 ..< 20:
      factors.incl(initSim(fixtureConfig(seed = seed)).seatOfProfile[pFactor])
    check factors.len > 1
    ## The same seed and the same moves give an identical log and results.
    var a = initSim(fixtureConfig(turns = 6, seed = 77))
    var b = initSim(fixtureConfig(turns = 6, seed = 77))
    check a.profileOf == b.profileOf
    check a.names == b.names
    while not a.done:
      a.passAll()
      b.passAll()
    check a.events.len == b.events.len
    for index in 0 ..< a.events.len:
      check $eventToJson(a.events[index]) == $eventToJson(b.events[index])
    check $a.resultsJson() == $b.resultsJson()

  test "the floor opens with the classic endowment":
    let sim = initSim(fixtureConfig())
    check sim.turn == 0
    check sim.turnsPlayed == 0
    check sim.phase == phMoves
    check sim.pendingSeats() == @[0, 1, 2, 3]
    for seat in 0 ..< Seats:
      let profile = sim.profileOf[seat]
      ## Endowment plus turn 0's production, which openTurn already ran.
      check sim.seats[seat].stock[gOre] ==
        StartStock + Production[profile][gOre]
      check sim.seats[seat].stock[gHearts] == StartHearts
      check sim.seats[seat].escrowed == [gOre: 0, gGrain: 0, gTimber: 0,
        gHearts: 0]
    check sim.events.len == 2
    check sim.events[0].kind == evStart
    check sim.events[1].kind == evTurn
    check sim.events[1].seats.len == Seats
    check sim.contracts.len == 0

suite "production and commissions":
  test "2. two hand-computed turns for all four profiles, with the fill cap":
    var sim = initSim(fixtureConfig(turns = 8, seed = 3))
    let mason = sim.seatOfProfile[pMason]
    let farmer = sim.seatOfProfile[pFarmer]
    let forester = sim.seatOfProfile[pForester]
    let factor = sim.seatOfProfile[pFactor]
    ## Turn 0, post-production: 3/3/3 + the profile yield.
    check sim.seats[mason].stock == [gOre: 9, gGrain: 4, gTimber: 4,
      gHearts: 20]
    check sim.seats[farmer].stock == [gOre: 4, gGrain: 9, gTimber: 4,
      gHearts: 20]
    check sim.seats[forester].stock == [gOre: 4, gGrain: 4, gTimber: 9,
      gHearts: 20]
    check sim.seats[factor].stock == [gOre: 5, gGrain: 5, gTimber: 5,
      gHearts: 20]
    sim.passAll()
    ## Everyone fills the cap of two copies on turn 0.
    check sim.seats[mason].stock == [gOre: 9, gGrain: 0, gTimber: 0,
      gHearts: 40]
    check sim.seats[farmer].stock == [gOre: 0, gGrain: 9, gTimber: 0,
      gHearts: 40]
    check sim.seats[forester].stock == [gOre: 0, gGrain: 0, gTimber: 9,
      gHearts: 40]
    check sim.seats[factor].stock == [gOre: 1, gGrain: 1, gTimber: 1,
      gHearts: 44]
    for seat in 0 ..< Seats:
      check sim.seats[seat].fills == 2
    check sim.heartsMinted() == 84
    ## Turn 1: the three specialists are one unit short of a single copy,
    ## and there is no such thing as a partial fill.
    check sim.turn == 1
    check sim.seats[mason].stock == [gOre: 15, gGrain: 1, gTimber: 1,
      gHearts: 40]
    sim.passAll()
    check sim.seats[mason].fills == 2
    check sim.seats[farmer].fills == 2
    check sim.seats[forester].fills == 2
    check sim.seats[mason].stock == [gOre: 15, gGrain: 1, gTimber: 1,
      gHearts: 40]
    ## Only the Factor, which produces every good it consumes, keeps going.
    check sim.seats[factor].fills == 3
    check sim.seats[factor].stock == [gOre: 1, gGrain: 1, gTimber: 1,
      gHearts: 56]
    check sim.heartsMinted() == 96

suite "the contract language":
  test "3. the parser table: every valid form, and every rejection reason":
    let sim = initSim(fixtureConfig(turns = 16, seed = 5))
    let me = sim.seatOfProfile[pMason]
    let you = sim.seatOfProfile[pFarmer]
    let third = sim.seatOfProfile[pForester]
    let them = sim.names[you]

    ## --- valid forms ---
    for text in [
      sim.offerText(you, "5 ORE", "12 HEARTS", "6", "ALWAYS", "SWAP", "KEEP"),
      sim.offerText(you, "5 ORE + 2 GRAIN", "12 HEARTS", "1", "ALWAYS",
        "KEEP", "KEEP"),
      sim.offerText(you, "NOTHING", "3 HEARTS", "2", "ALWAYS", "PROPOSER",
        "ACCEPTOR"),
      sim.offerText(you, "1 ORE", "NOTHING", "2", "HOLDS " & them &
        " 4 GRAIN", "ACCEPTOR", "PROPOSER"),
      sim.offerText(you, "1 ORE", "1 GRAIN", "3", "NOT HOLDS " & them &
        " 4 GRAIN", "SWAP", "KEEP"),
      sim.offerText(you, "1 ORE", "1 GRAIN", "3", "PAID " & them &
        " 4 TIMBER", "SWAP", "PROPOSER"),
      sim.offerText(you, "1 ORE", "1 GRAIN", "3", "NOT PAID " &
        sim.names[me] & " 4 ORE", "SWAP", "PROPOSER"),
      ## Lower case is understood; the board still reads upper case.
      "offer " & them.toLowerAscii() & "\nlock 2 ore\nask 5 hearts\n" &
        "due 4\nif always\nthen swap\nelse keep"
    ]:
      let parsed = parseContract(text, sim, me)
      check parsed.ok
      check parsed.reason == ""
      check parsed.contract.acceptor == you
      check parsed.contract.text.startsWith("OFFER " & them)

    ## The three-term bundle and every payout keyword round-trip.
    let rich = parseContract(sim.offerText(you, "1 ORE + 2 GRAIN + 3 TIMBER",
      "9 HEARTS", "5", "ALWAYS", "PROPOSER", "ACCEPTOR"), sim, me)
    check rich.ok
    check rich.contract.lock == [gOre: 1, gGrain: 2, gTimber: 3, gHearts: 0]
    check rich.contract.ask == [gOre: 0, gGrain: 0, gTimber: 0, gHearts: 9]
    check rich.contract.thenPay == poProposer
    check rich.contract.elsePay == poAcceptor
    check rich.contract.due == 5

    ## --- one case per rejection reason ---
    proc why(text: string): string =
      parseContract(text, sim, me).reason

    check why("OFFER " & them & "\nLOCK 5 ORE") == "syntax"
    check why("LOCK 5 ORE\nOFFER " & them & "\nASK 1 GRAIN\nDUE 2\n" &
      "IF ALWAYS\nTHEN SWAP\nELSE KEEP") == "syntax"
    check why(sim.offerText(you, "5 ORE", "1 GRAIN", "2", "ALWAYS", "SWAP",
      "KEEP") & "\n" & "x".repeat(250)) == "too_long"
    check why("OFFER Nobody\nLOCK 5 ORE\nASK 1 GRAIN\nDUE 2\nIF ALWAYS\n" &
      "THEN SWAP\nELSE KEEP") == "bad_target"
    check why(sim.offerText(me, "5 ORE", "1 GRAIN", "2", "ALWAYS", "SWAP",
      "KEEP")) == "bad_target"
    check why(sim.offerText(you, "5 SHEEP", "1 GRAIN", "2", "ALWAYS", "SWAP",
      "KEEP")) == "bad_bundle"
    check why(sim.offerText(you, "0 ORE", "1 GRAIN", "2", "ALWAYS", "SWAP",
      "KEEP")) == "bad_bundle"
    check why(sim.offerText(you, "2 ORE + 3 ORE", "1 GRAIN", "2", "ALWAYS",
      "SWAP", "KEEP")) == "bad_bundle"
    check why(sim.offerText(you, "1 ORE + 1 GRAIN + 1 TIMBER + 1 HEARTS",
      "1 GRAIN", "2", "ALWAYS", "SWAP", "KEEP")) == "bad_bundle"
    check why(sim.offerText(you, "NOTHING", "NOTHING", "2", "ALWAYS", "SWAP",
      "KEEP")) == "bad_bundle"
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "0", "ALWAYS", "SWAP",
      "KEEP")) == "bad_due"
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "7", "ALWAYS", "SWAP",
      "KEEP")) == "bad_due"
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "soon", "ALWAYS", "SWAP",
      "KEEP")) == "bad_due"
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "2", "HOLDS Nobody 4 ORE",
      "SWAP", "KEEP")) == "bad_condition"
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "2", "SOMETIMES", "SWAP",
      "KEEP")) == "bad_condition"
    ## PAID may only name one of the two parties.
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "2", "PAID " &
      sim.names[third] & " 4 ORE", "SWAP", "KEEP")) == "bad_condition"
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "2", "ALWAYS", "GIVE",
      "KEEP")) == "bad_payout"
    check why(sim.offerText(you, "1 ORE", "1 GRAIN", "2", "ALWAYS", "SWAP",
      "TAKE")) == "bad_payout"
    ## The Mason holds 9 ore on turn 0, not 99.
    check why(sim.offerText(you, "99 ORE", "1 GRAIN", "2", "ALWAYS", "SWAP",
      "KEEP")) == "unfunded"
    ## Four live contracts is the cap, in either role.
    var capped = sim
    for index in 0 ..< MaxLive:
      capped.contracts.add(Contract(id: "X" & $index, proposer: me,
        acceptor: you, status: csOffered, postedTurn: 0, signedTurn: -1))
    check parseContract(sim.offerText(you, "1 ORE", "1 GRAIN", "2", "ALWAYS",
      "SWAP", "KEEP"), capped, me).reason == "contract_cap"

  test "4. normalization is idempotent":
    let sim = initSim(fixtureConfig(turns = 16, seed = 5))
    let me = sim.seatOfProfile[pMason]
    let you = sim.seatOfProfile[pFarmer]
    let raw = "offer   " & sim.names[you].toLowerAscii() &
      "\n  lock 5 ore+2 grain \nask   12 hearts\ndue 6\n" &
      "if not holds " & sim.names[you].toLowerAscii() &
      " 4 grain\nthen proposer\nelse keep"
    let first = parseContract(raw, sim, me)
    check first.ok
    let second = parseContract(first.contract.text, sim, me)
    check second.ok
    check second.contract.text == first.contract.text
    check first.contract.text ==
      "OFFER " & sim.names[you] & "\nLOCK 5 ORE + 2 GRAIN\n" &
      "ASK 12 HEARTS\nDUE 6\nIF NOT HOLDS " & sim.names[you] &
      " 4 GRAIN\nTHEN PROPOSER\nELSE KEEP"
    check renderContract(sim, second.contract) == first.contract.text

# ---------------------------------------------------------------------------

proc tradeSim(thenPay, elsePay: string, condTrue: bool, due = "1",
    doSign = true, turns = 8, seed = 5): Sim =
  ## Turn 0: the Mason posts a funded 5-ore-for-5-grain contract to the
  ## Farmer. Turn 1: the Farmer signs it. With `due` 1 it settles in the
  ## same turn it is signed.
  result = initSim(fixtureConfig(turns = turns, seed = seed))
  let mason = result.seatOfProfile[pMason]
  let farmer = result.seatOfProfile[pFarmer]
  ## The Farmer's free timber on turn 1 is 1, so "40 TIMBER" is the
  ## condition that reads false.
  let cond =
    if condTrue: "ALWAYS"
    else: "HOLDS " & result.names[farmer] & " 40 TIMBER"
  var first: array[Seats, Move]
  first[mason] = Move(offer: result.offerText(farmer, "5 ORE", "5 GRAIN",
    due, cond, thenPay, elsePay))
  result.moveAll(first)
  var second: array[Seats, Move]
  if doSign:
    second[farmer] = Move(signs: @["C1"])
  result.moveAll(second)

suite "escrow mechanics":
  test "5. posting locks the proposer, signing locks the acceptor":
    var sim = tradeSim("SWAP", "KEEP", true, due = "2")
    let mason = sim.seatOfProfile[pMason]
    let farmer = sim.seatOfProfile[pFarmer]
    ## Still signed at the end of turn 1 because it is not due until 2.
    check sim.contracts.len == 1
    check sim.contracts[0].status == csSigned
    check sim.contracts[0].signedTurn == 1
    check sim.seats[mason].escrowed[gOre] == 5
    check sim.seats[farmer].escrowed[gGrain] == 5
    check sim.seats[mason].signedCount == 1
    check sim.seats[farmer].signedCount == 1
    ## Turn 2 has opened, so the Farmer now holds 16 free grain and 5 more
    ## locked in C1. HOLDS reads FREE stock ONLY: a 16-grain clause is true
    ## and a 20-grain clause is false, even though it holds 21 in total.
    ## That is the loophole, stated as an assertion.
    check sim.turn == 2
    check sim.seats[farmer].stock[gGrain] == 16
    check sim.seats[farmer].escrowed[gGrain] == 5
    var probe = sim.contracts[0]
    probe.cond = Condition(kind: ckHolds, who: farmer, n: 16, good: gGrain)
    check sim.evalCondition(probe)
    probe.cond = Condition(kind: ckHolds, who: farmer, n: 20, good: gGrain)
    check not sim.evalCondition(probe)
    ## And escrowed stock cannot be given away: 20 grain is inside the
    ## Farmer's total holding but outside its free stock.
    var giving: array[Seats, Move]
    giving[farmer] = Move(gives: @[GiveOrder(to: mason, n: 20, good: gGrain)])
    sim.moveAll(giving)
    let give = sim.lastOf(evGive)
    check not give.ok
    check give.seat == farmer

  test "5b. escrowed stock cannot fill a commission":
    var free = initSim(fixtureConfig(turns = 8, seed = 5))
    free.passAll()
    let factorSeat = free.seatOfProfile[pFactor]
    check free.seats[factorSeat].fills == 2

    var locked = initSim(fixtureConfig(turns = 8, seed = 5))
    let factor = locked.seatOfProfile[pFactor]
    let mason = locked.seatOfProfile[pMason]
    var moves: array[Seats, Move]
    ## The Factor holds 5 ore and needs 4 of them for two fills; locking 4
    ## in an unrelated contract starves its own bench.
    moves[factor] = Move(offer: locked.offerText(mason, "4 ORE", "1 HEARTS",
      "1", "ALWAYS", "SWAP", "KEEP"))
    locked.moveAll(moves)
    check locked.seats[factor].escrowed[gOre] == 4
    check locked.seats[factor].stock[gOre] == 1
    check locked.seats[factor].fills == 0

  test "5c. an unaffordable sign leaves the contract offered and moves nothing":
    var sim = initSim(fixtureConfig(turns = 8, seed = 5))
    let mason = sim.seatOfProfile[pMason]
    let farmer = sim.seatOfProfile[pFarmer]
    var first: array[Seats, Move]
    first[mason] = Move(offer: sim.offerText(farmer, "1 ORE", "99 HEARTS",
      "2", "ALWAYS", "SWAP", "KEEP"))
    sim.moveAll(first)
    check sim.contracts.len == 1
    let heartsBefore = sim.seats[farmer].stock[gHearts]
    check heartsBefore < 99
    var second: array[Seats, Move]
    second[farmer] = Move(signs: @["C1"])
    sim.moveAll(second)
    let sign = sim.lastOf(evSign)
    check not sign.ok
    check sign.id == "C1"
    check sim.seats[farmer].escrowed[gHearts] == 0
    check sim.contracts[0].status == csExpired  ## it expired the same turn
    check sim.seats[mason].escrowed[gOre] == 0  ## and the proposer got it back

suite "settlement":
  test "6. all four payouts against both condition outcomes":
    for condTrue in [true, false]:
      for pay in ["SWAP", "KEEP", "PROPOSER", "ACCEPTOR"]:
        ## Put `pay` on whichever branch the condition selects, and a KEEP
        ## on the other, so the settle event must report exactly `pay`.
        let sim =
          if condTrue: tradeSim(pay, "KEEP", true)
          else: tradeSim("KEEP", pay, false)
        let mason = sim.seatOfProfile[pMason]
        let farmer = sim.seatOfProfile[pFarmer]
        let settle = sim.lastOf(evSettle)
        check settle.id == "C1"
        check settle.held == condTrue
        check settle.branch == (if condTrue: "then" else: "else")
        check $settle.payout == pay
        check sim.contracts[0].status == csSettled
        ## Nothing stays locked once a contract settles.
        check sim.seats[mason].escrowed == [gOre: 0, gGrain: 0, gTimber: 0,
          gHearts: 0]
        check sim.seats[farmer].escrowed == [gOre: 0, gGrain: 0, gTimber: 0,
          gHearts: 0]
        var toMason: array[Good, int]
        var toFarmer: array[Good, int]
        for leg in settle.legs:
          if leg.to == mason: toMason[leg.good] += leg.n
          elif leg.to == farmer: toFarmer[leg.good] += leg.n
        case pay
        of "SWAP":
          check toMason == [gOre: 0, gGrain: 5, gTimber: 0, gHearts: 0]
          check toFarmer == [gOre: 5, gGrain: 0, gTimber: 0, gHearts: 0]
        of "KEEP":
          check toMason == [gOre: 5, gGrain: 0, gTimber: 0, gHearts: 0]
          check toFarmer == [gOre: 0, gGrain: 5, gTimber: 0, gHearts: 0]
        of "PROPOSER":
          check toMason == [gOre: 5, gGrain: 5, gTimber: 0, gHearts: 0]
          check toFarmer == [gOre: 0, gGrain: 0, gTimber: 0, gHearts: 0]
          check sim.seats[farmer].forfeits == 1
          check sim.seats[mason].forfeits == 0
        else:
          check toFarmer == [gOre: 5, gGrain: 5, gTimber: 0, gHearts: 0]
          check toMason == [gOre: 0, gGrain: 0, gTimber: 0, gHearts: 0]
          check sim.seats[mason].forfeits == 1
          check sim.seats[farmer].forfeits == 0

  test "6b. PAID counts only gives to the counterparty at or after signing":
    proc paidRun(negated: bool, payTurn: int, toThird: bool): Sim =
      result = initSim(fixtureConfig(turns = 8, seed = 5))
      let mason = result.seatOfProfile[pMason]
      let farmer = result.seatOfProfile[pFarmer]
      let forester = result.seatOfProfile[pForester]
      let target = if toThird: forester else: mason
      let cond = (if negated: "NOT " else: "") & "PAID " &
        result.names[farmer] & " 2 GRAIN"
      var first: array[Seats, Move]
      first[mason] = Move(offer: result.offerText(farmer, "5 ORE", "5 GRAIN",
        "1", cond, "SWAP", "PROPOSER"))
      if payTurn == 0:
        first[farmer] = Move(gives: @[
          GiveOrder(to: target, n: 2, good: gGrain)])
      result.moveAll(first)
      var second: array[Seats, Move]
      second[farmer] = Move(signs: @["C1"])
      if payTurn == 1:
        second[farmer].gives = @[GiveOrder(to: target, n: 2, good: gGrain)]
      result.moveAll(second)

    ## Paid on the same turn as the signature: the clause holds.
    let onTime = paidRun(false, 1, false)
    check onTime.lastOf(evSettle).held
    check $onTime.lastOf(evSettle).payout == "SWAP"
    ## Paid BEFORE the contract was signed: it does not count.
    let early = paidRun(false, 0, false)
    check not early.lastOf(evSettle).held
    check $early.lastOf(evSettle).payout == "PROPOSER"
    ## Paid to somebody else entirely: it does not count.
    let wrongWay = paidRun(false, 1, true)
    check not wrongWay.lastOf(evSettle).held
    ## Never paid at all.
    let never = paidRun(false, -1, false)
    check not never.lastOf(evSettle).held
    ## NOT inverts every one of those.
    check not paidRun(true, 1, false).lastOf(evSettle).held
    check paidRun(true, 0, false).lastOf(evSettle).held
    check paidRun(true, -1, false).lastOf(evSettle).held

suite "expiry, the horizon, and scoring":
  test "7. an offer lives exactly one turn; the horizon refunds everything":
    var sim = tradeSim("SWAP", "KEEP", true, due = "3", doSign = false)
    let mason = sim.seatOfProfile[pMason]
    ## Posted on turn 0, unsigned on turn 1, therefore expired on turn 1.
    check sim.contracts[0].status == csExpired
    let expire = sim.lastOf(evExpire)
    check expire.id == "C1"
    check expire.seat == mason
    check sim.seats[mason].escrowed[gOre] == 0
    check sim.seats[mason].stock[gOre] >= 5

    ## A signed contract caught by an early stop closes as KEEP.
    var live = tradeSim("PROPOSER", "PROPOSER", true, due = "3")
    let masonB = live.seatOfProfile[pMason]
    let farmerB = live.seatOfProfile[pFarmer]
    check live.contracts[0].status == csSigned
    let masonOre = live.seats[masonB].stock[gOre]
    let farmerGrain = live.seats[farmerB].stock[gGrain]
    live.endEarly()
    check live.contracts[0].status == csSettled
    let closed = live.lastOf(evSettle)
    check closed.branch == "horizon"
    check $closed.payout == "KEEP"
    check live.seats[masonB].stock[gOre] == masonOre + 5
    check live.seats[farmerB].stock[gGrain] == farmerGrain + 5
    check live.seats[masonB].escrowed[gOre] == 0
    check live.seats[farmerB].escrowed[gGrain] == 0
    ## Nobody forfeited: a horizon closure is not a loss.
    for seat in 0 ..< Seats:
      check live.seats[seat].forfeits == 0
      check live.score(seat) == live.seats[seat].stock[gHearts]

  test "8. hearts and goods are conserved at the end of every turn":
    ## A deterministic mixed episode: seat 0 posts, seat 1 signs, seat 2
    ## gives, seat 3 passes — enough traffic to move escrow every turn.
    var sim = initSim(fixtureConfig(turns = 12, seed = 9))
    var opened = 1
    while not sim.done:
      var moves: array[Seats, Move]
      if sim.turn + 1 <= sim.config.turns - 1 and
          sim.seats[0].stock[gOre] >= 2:
        moves[0] = Move(offer: sim.offerText(1, "2 ORE", "2 GRAIN", $(sim.turn + 1),
          "ALWAYS", "SWAP", "KEEP"))
      for contract in sim.contracts:
        if contract.status == csOffered and contract.acceptor == 1 and
            contract.postedTurn == sim.turn - 1:
          moves[1] = Move(signs: @[contract.id])
      if sim.seats[2].stock[gTimber] >= 1:
        moves[2] = Move(gives: @[GiveOrder(to: 3, n: 1, good: gTimber)])
      sim.moveAll(moves)
      if not sim.done:
        inc opened

      var hearts = 0
      var goods: array[Good, int]
      var consumed: array[Good, int]
      for seat in 0 ..< Seats:
        hearts += sim.seats[seat].stock[gHearts] +
          sim.seats[seat].escrowed[gHearts]
        for good in Good:
          goods[good] += sim.seats[seat].stock[good] +
            sim.seats[seat].escrowed[good]
          consumed[good] += sim.seats[seat].fills *
            Commission[sim.profileOf[seat]][good]
      ## Commissions are the ONLY mint; every other movement is a transfer.
      check hearts == Seats * StartHearts + sim.heartsMinted()
      for good in [gOre, gGrain, gTimber]:
        ## Each profile appears once, so the floor produces 10 of every
        ## good per turn opened.
        check goods[good] == Seats * StartStock + opened * 10 - consumed[good]
    check sim.reason == "complete"
    check sim.turnsPlayed == 12

  test "9. endEarly settles between turns with the turns played":
    var sim = initSim(fixtureConfig(turns = 10, seed = 5))
    sim.passAll()
    sim.passAll()
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.turnsPlayed == 2
    check sim.pendingSeats().len == 0
    let results = sim.resultsJson()
    check results["reason"].getStr() == "deadline"
    check results["turns"].getInt() == 2
    check results["maxTurns"].getInt() == 10
    check results["names"].len == Seats
    check results["scores"].len == Seats
    for seat in 0 ..< Seats:
      check results["scores"][seat].getInt() == sim.score(seat)
      check results["hearts"][seat].getInt() == sim.seats[seat].stock[gHearts]
      check results["scores"][seat].getInt() >= 0
    check sim.events[^1].kind == evEnd
    check sim.events[^1].text == "deadline"
    ## Idempotent: a second stop changes nothing.
    sim.endEarly()
    check sim.events[^1].kind == evEnd
    expect EscrowError:
      sim.applyMove(0, Move(), true)

suite "replay":
  proc busySim(turns = 6, seed = 11): Sim =
    ## An episode that emits every event kind: a good offer, a refused
    ## one, a signature, a give, a settlement, an expiry and fills.
    result = initSim(fixtureConfig(turns = turns, seed = seed))
    let mason = result.seatOfProfile[pMason]
    let farmer = result.seatOfProfile[pFarmer]
    let forester = result.seatOfProfile[pForester]
    let factor = result.seatOfProfile[pFactor]
    var first: array[Seats, Move]
    first[mason] = Move(offer: result.offerText(farmer, "5 ORE", "5 GRAIN",
      "1", "ALWAYS", "SWAP", "KEEP"), say: "ore at 2.5 a unit",
      notes: "farmer is short of ore")
    first[forester] = Move(gives: @[GiveOrder(to: factor, n: 1, good: gTimber)])
    first[factor] = Move(offer: "GIVE ME EVERYTHING")   ## a refused draft
    result.moveAll(first)
    var second: array[Seats, Move]
    second[farmer] = Move(signs: @["C1"], say: "signed")
    second[mason] = Move(offer: result.offerText(forester, "1 ORE",
      "1 TIMBER", "4", "NOT HOLDS " & result.names[forester] & " 99 TIMBER",
      "SWAP", "PROPOSER"))
    result.moveAll(second)
    ## Nobody signs C2, so it expires on turn 2.
    while not result.done:
      result.passAll()

  test "10. a recorded episode re-derives frame by frame":
    let config = fixtureConfig(turns = 6, seed = 11)
    let live = busySim()
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].done
    check frames[^1].reason == "complete"
    check $frames[^1].resultsJson() == $live.resultsJson()
    ## A recorded deadline stop is honoured, closure and all.
    var short = initSim(config)
    short.passAll()
    short.endEarly()
    let shortFrames = replayMatch(config, short.events)
    check shortFrames[^1].done
    check shortFrames[^1].reason == "deadline"
    check shortFrames[^1].turnsPlayed == 1
    ## A tampered turn event is rejected.
    var events = live.events
    var index = -1
    for position, event in events:
      if event.kind == evTurn and event.turn == 2:
        index = position
    check index >= 0
    events[index].seats[0].stock[gOre] += 1
    expect EscrowError:
      discard replayMatch(config, events)

  test "11. every event kind round-trips through JSON":
    let live = busySim()
    var kinds = initHashSet[EventKind]()
    for event in live.events:
      kinds.incl(event.kind)
      let back = eventFromJson(eventToJson(event))
      check back.kind == event.kind
      check back.turn == event.turn
      check back.seat == event.seat
      check back.text == event.text
      check back.say == event.say
      check back.offer == event.offer
      check back.id == event.id
      check back.ok == event.ok
      check back.scripted == event.scripted
      check back.gives.len == event.gives.len
      for i in 0 ..< event.gives.len:
        check back.gives[i].to == event.gives[i].to
        check back.gives[i].n == event.gives[i].n
        check back.gives[i].good == event.gives[i].good
      check back.signs == event.signs
      check back.legs.len == event.legs.len
      for i in 0 ..< event.legs.len:
        check back.legs[i].to == event.legs[i].to
        check back.legs[i].n == event.legs[i].n
        check back.legs[i].good == event.legs[i].good
      check back.seats.len == event.seats.len
      for i in 0 ..< event.seats.len:
        check back.seats[i].stock == event.seats[i].stock
        check back.seats[i].escrowed == event.seats[i].escrowed
        check back.seats[i].fills == event.seats[i].fills
      check back.board.len == event.board.len
      for i in 0 ..< event.board.len:
        check back.board[i].id == event.board[i].id
        check back.board[i].lock == event.board[i].lock
        check back.board[i].ask == event.board[i].ask
        check back.board[i].due == event.board[i].due
        check back.board[i].status == event.board[i].status
        check back.board[i].cond.kind == event.board[i].cond.kind
        check back.board[i].cond.negated == event.board[i].cond.negated
        check back.board[i].cond.who == event.board[i].cond.who
      case event.kind
      of evSettle:
        check back.held == event.held
        check back.branch == event.branch
        check back.payout == event.payout
        check back.cond == event.cond
      of evOffer:
        check back.dsl == event.dsl
        check back.lock == event.lock
        check back.ask == event.ask
        check back.due == event.due
        check back.thenPay == event.thenPay
        check back.elsePay == event.elsePay
        check back.target == event.target
      of evGive:
        check back.target == event.target
        check back.n == event.n
        check back.good == event.good
      of evFill:
        check back.n == event.n
        check back.hearts == event.hearts
      else:
        discard
    for kind in EventKind:
      check kind in kinds

  test "12. replay bytes are strict UTF-8 even at a truncation boundary":
    var sim = initSim(fixtureConfig(turns = 6, seed = 3))
    let mason = sim.seatOfProfile[pMason]
    let farmer = sim.seatOfProfile[pFarmer]
    ## Multi-byte runes right up to the cap, with an emoji sitting exactly
    ## on the cut. A byte slice here would leave invalid UTF-8 in the
    ## replay and break its JSON; runeSubStr does not.
    var say = "é".repeat(MaxSayLen - 1) & "🐐" & "é".repeat(20)
    var notes = "ü".repeat(MaxNotesLen - 1) & "🐐" & "ü".repeat(20)
    var offer = "OFFER " & sim.names[farmer] & "\nLOCK 5 ORE\nASK 5 GRAIN\n" &
      "DUE 1\nIF ALWAYS\nTHEN SWAP\nELSE KEEP\n" & "🐐".repeat(300)
    check say.runeLen > MaxSayLen
    check notes.runeLen > MaxNotesLen
    check offer.runeLen > MaxOfferChars
    var moves: array[Seats, Move]
    moves[mason] = Move(offer: offer, say: say, notes: notes)
    sim.moveAll(moves)
    check sim.says[mason].runeLen == MaxSayLen
    check sim.says[mason].validateUtf8() == -1
    check sim.notes[mason].runeLen == MaxNotesLen
    check sim.notes[mason].validateUtf8() == -1
    ## A truncated contract fails the parser, which is a refusal, not a
    ## crash — and the refusal text is itself valid UTF-8.
    check sim.has(evReject)
    while not sim.done:
      sim.passAll()

    var events = newJArray()
    for event in sim.events:
      events.add(eventToJson(event))
      check event.say.validateUtf8() == -1
      check event.text.validateUtf8() == -1
      check event.offer.validateUtf8() == -1
    var names = newJArray()
    for name in sim.names:
      names.add(%name)
    let bytes = $ %*{
      "protocol": "escrow.replay.v1",
      "names": names,
      "policyNames": names,
      "config": {"turns": sim.config.turns, "seed": sim.config.seed,
        "talk": sim.config.talk, "sampled": true},
      "events": events,
      "results": sim.resultsJson()
    }
    check bytes.validateUtf8() == -1
    let parsed = parseJson(bytes)
    check parsed["events"].len == sim.events.len
    for node in parsed["events"]:
      if node.hasKey("say"):
        check node["say"].getStr().validateUtf8() == -1
      if node.hasKey("text"):
        check node["text"].getStr().validateUtf8() == -1
