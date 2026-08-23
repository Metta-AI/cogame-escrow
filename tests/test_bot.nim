## The scripted baselines must play whole episodes without ever proposing
## an illegal action — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## The `trader` baseline must also be a partner worth beating: an episode
## of four traders has to mint materially more hearts than the autarky
## floor, or the price band is broken.

import std/[json, monotimes, nativesockets, net, os, strutils, times,
  unicode, unittest]
import escrow/[llm, sim]

## ---- A stub Bedrock endpoint ------------------------------------------
## Test 18 needs a reply that PARSES and VALIDATES: that is the only way
## to execute the line which records a decision as the MODEL's own
## (`scripted: false`). curly speaks real HTTP over a real socket, so the
## endpoint is a real socket too.

var
  stubServed = 0     ## replies handed out; read only after the join
  stubStop = false   ## set by the test to retire the thread

proc stubServe(arg: tuple[fd: SocketHandle, reply: string]) {.thread.} =
  let listener = newSocket(arg.fd, AF_INET, SOCK_STREAM, IPPROTO_TCP)
  var idle = 0
  ## Bounded twice over: the test flips `stubStop`, and 10 s of silence
  ## retires the thread anyway, so a broken test can never hang CI.
  while not stubStop and idle < 50:
    var waiting = @[arg.fd]
    if selectRead(waiting, 200) <= 0:
      inc idle
      continue
    idle = 0
    var client: Socket
    try:
      listener.accept(client)
    except CatchableError:
      break
    try:
      var request = ""
      while not request.contains("\r\n\r\n"):
        let chunk = client.recv(4096, timeout = 5000)
        if chunk.len == 0:
          break
        request.add(chunk)
      ## libcurl sends a body this size in two steps.
      if "100-continue" in request.toLowerAscii():
        client.send("HTTP/1.1 100 Continue\r\n\r\n")
      var length = 0
      for line in request.split("\r\n"):
        if line.toLowerAscii().startsWith("content-length:"):
          length = line[15 .. ^1].strip().parseInt()
      var body = request[request.find("\r\n\r\n") + 4 .. ^1]
      while body.len < length:
        let chunk = client.recv(min(4096, length - body.len), timeout = 5000)
        if chunk.len == 0:
          break
        body.add(chunk)
      client.send("HTTP/1.1 200 OK\r\n" &
        "content-type: application/json\r\n" &
        "content-length: " & $arg.reply.len & "\r\n" &
        "connection: close\r\n\r\n" & arg.reply)
      inc stubServed
    except CatchableError:
      discard
    client.close()

proc fixture(seed: int, turns = 16, talk = true): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.turns = turns
  result.talk = talk
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.pendingSeats():
      let decision = scriptedAction(result, seat, kinds[seat])
      ## Legal BY CONSTRUCTION: the strict validator the LLM path uses to
      ## reject a model reply must accept every scripted decision as-is.
      check result.validateMove(seat, decision) == ""
      check decision.say.len == 0
      check decision.notes.len == 0
      check decision.gives.len <= MaxGives
      check decision.signs.len <= MaxSigns
      if decision.offer.len > 0:
        check decision.offer.runeLen <= MaxOfferChars
        let parsed = parseContract(decision.offer, result, seat)
        check parsed.ok
        check parsed.contract.due >= result.turn + 1
        check parsed.contract.due <=
          min(result.turn + DueWindow, config.turns - 1)
        for good in Good:
          check parsed.contract.lock[good] >= 0
          check parsed.contract.lock[good] <= MaxUnits
          check parsed.contract.ask[good] >= 0
          check parsed.contract.ask[good] <= MaxUnits
      result.applyMove(seat, decision, true)
      for other in 0 ..< Seats:
        check result.liveContracts(other) <= MaxLive

proc assertCleanLog(sim: Sim) =
  ## No rejection of any kind may be attributed to a scripted seat.
  for event in sim.events:
    case event.kind
    of evReject:
      checkpoint("scripted seat was rejected: " & event.text)
      check false
    of evSign, evGive:
      checkpoint("scripted action failed: " & event.text)
      check event.ok
    of evMove:
      check event.say.len == 0
      check event.text.len == 0
    else:
      discard

suite "scripted baselines":
  test "13. every scripted action is legal, across seeds and mixes":
    let mixes = [
      [skTrader, skTrader, skTrader, skTrader],
      [skTrader, skTrader, skTrader, skHoarder],
      [skTrader, skTrader, skHoarder, skHoarder]
    ]
    let started = getMonoTime()
    for seed in [1, 7, 42, 1234]:
      for kinds in mixes:
        let config = fixture(seed)
        let sim = playScripted(config, kinds)
        check sim.done
        check sim.reason == "complete"
        check sim.turnsPlayed == config.turns
        sim.assertCleanLog()
        var moves = 0
        for event in sim.events:
          if event.kind == evMove:
            inc moves
            check event.scripted
        check moves == config.turns * Seats
        ## Contracts either settled or expired; nothing is left stranded.
        for contract in sim.contracts:
          check contract.status in {csSettled, csExpired}
        for seat in 0 ..< Seats:
          check sim.seats[seat].escrowed ==
            [gOre: 0, gGrain: 0, gTimber: 0, gHearts: 0]
          check sim.score(seat) >= 0
    let elapsed = (getMonoTime() - started).inMilliseconds
    echo "scripted mixes: ", elapsed, " ms"
    check elapsed < 2000

  test "13b. the hoarder never touches the board":
    let sim = playScripted(fixture(7, turns = 12),
      [skHoarder, skHoarder, skHoarder, skHoarder])
    check sim.done
    check sim.contracts.len == 0
    check sim.transfers.len == 0
    for event in sim.events:
      check event.kind notin {evOffer, evSign, evGive, evReject, evExpire,
        evSettle}

  test "14. trading beats autarky: heartsMinted is at least 1.3x":
    for seed in [1, 7, 42, 1234]:
      let traded = playScripted(fixture(seed),
        [skTrader, skTrader, skTrader, skTrader])
      let autarky = playScripted(fixture(seed),
        [skHoarder, skHoarder, skHoarder, skHoarder])
      check autarky.heartsMinted() > 0
      echo "seed ", seed, ": traded ", traded.heartsMinted(),
        " vs autarky ", autarky.heartsMinted(), " hearts minted"
      ## A canary for a broken price band as much as for a broken bot.
      check traded.heartsMinted() * 10 >= autarky.heartsMinted() * 13
      var signedAny = 0
      for seat in 0 ..< Seats:
        signedAny += traded.seats[seat].signedCount
      check signedAny > 0

  test "15. decideAll falls back to scripted with no credentials, instantly":
    let config = fixture(3, turns = 8)
    let client = newLlmClient(config)
    ## CI never sets ANTHROPIC_API_KEY: this is the path offline
    ## certification and docker_smoke.sh take, and it is load-bearing.
    check client.disabled
    var sim = initSim(config)
    let started = getMonoTime()
    while not sim.done:
      let seats = sim.pendingSeats()
      let decisions = client.decideAll(sim, seats,
        @["be bold", "", "", ""], @[skNone, skNone, skHoarder, skNone])
      check decisions.len == seats.len
      for index, seat in seats:
        let kind = if seat == 2: skHoarder else: skTrader
        let expected = scriptedAction(sim, seat, kind)
        check decisions[index].scripted
        check decisions[index].move.offer == expected.offer
        check decisions[index].move.signs == expected.signs
        check decisions[index].move.gives.len == expected.gives.len
        sim.applyMove(seat, decisions[index].move, decisions[index].scripted)
    check sim.reason == "complete"
    check sim.turnsPlayed == 8
    ## No network waits at all.
    check (getMonoTime() - started).inMilliseconds < 2000
    check parseScriptKind("1") == skTrader
    check parseScriptKind("trader") == skTrader
    check parseScriptKind("TRUE") == skTrader
    check parseScriptKind("hoarder") == skHoarder
    check parseScriptKind("autarky") == skHoarder
    check parseScriptKind("") == skNone
    check parseScriptKind("basestock") == skNone

  test "16. the reply-parsing table":
    var sim = initSim(fixture(5, turns = 12))
    let me = sim.seatOfProfile[pMason]
    let you = sim.names[sim.seatOfProfile[pFarmer]]
    let other = sim.names[sim.seatOfProfile[pForester]]

    ## A full, valid reply.
    let full = parseDecision(parseJson("""
      {"give": [{"to": "%YOU%", "n": 4, "good": "ORE"}],
       "offer": "OFFER %YOU%\nLOCK 5 ORE\nASK 12 HEARTS\nDUE 1\nIF ALWAYS\nTHEN SWAP\nELSE KEEP",
       "sign": ["C3"],
       "say": "Ore at 2.5 hearts a unit, first come.",
       "notes": "Gizmo is short timber until turn 9."}
    """.replace("%YOU%", you)), sim, me)
    check full.gives.len == 1
    check full.gives[0].to == sim.seatOfProfile[pFarmer]
    check full.gives[0].n == 4
    check full.gives[0].good == gOre
    check full.signs == @["C3"]
    check full.say == "Ore at 2.5 hearts a unit, first come."
    check full.notes.startsWith("Gizmo is short")
    check parseContract(full.offer, sim, me).ok

    ## Missing fields mean "no action"; {} is a legal reply meaning pass.
    let pass = parseDecision(parseJson("{}"), sim, me)
    check pass.gives.len == 0
    check pass.signs.len == 0
    check pass.offer == ""
    check pass.say == ""
    check pass.notes == ""
    check sim.validateMove(me, pass) == ""

    ## `n` may be an integer, a numeric string or a float.
    for raw in ["4", "\"4\"", "4.2", "\" 4 \""]:
      let one = parseDecision(parseJson(
        """{"give": [{"to": "%YOU%", "n": %N%, "good": "ore"}]}"""
          .replace("%YOU%", you).replace("%N%", raw)), sim, me)
      check one.gives[0].n == 4

    ## Entries past the cap are DROPPED, not fatal.
    let many = parseDecision(parseJson("""
      {"give": [{"to": "%YOU%", "n": 1, "good": "ORE"},
                {"to": "%OTHER%", "n": 1, "good": "ORE"},
                {"to": "%YOU%", "n": 9, "good": "ORE"}],
       "sign": ["C1", "C2", "C3"]}
    """.replace("%YOU%", you).replace("%OTHER%", other)), sim, me)
    check many.gives.len == MaxGives
    check many.gives[1].to == sim.seatOfProfile[pForester]
    check many.signs == @["C1", "C2"]

    ## Over-cap free text is truncated on RUNE boundaries, never bytes.
    let long = parseDecision(%*{
      "say": "é".repeat(400) & "🐐",
      "notes": "ü".repeat(900) & "🐐",
      "offer": "🐐".repeat(400)
    }, sim, me)
    check long.say.runeLen == MaxSayLen
    check long.say.validateUtf8() == -1
    check long.notes.runeLen == MaxNotesLen
    check long.notes.validateUtf8() == -1
    check long.offer.runeLen == MaxOfferChars
    check long.offer.validateUtf8() == -1
    check cleanText("é".repeat(900), MaxNotesLen).runeLen == MaxNotesLen
    check cleanText("é".repeat(900), MaxSayLen).runeLen == MaxSayLen

    ## A malformed entry invalidates the WHOLE reply, so the retry can
    ## quote the exact problem back to the model.
    expect EscrowError:
      discard parseDecision(parseJson(
        """{"give": [{"to": "%YOU%", "n": "lots", "good": "ORE"}]}"""
          .replace("%YOU%", you)), sim, me)
    expect EscrowError:
      discard parseDecision(parseJson(
        """{"give": [{"to": "Nobody", "n": 1, "good": "ORE"}]}"""), sim, me)
    expect EscrowError:
      discard parseDecision(parseJson(
        """{"give": [{"to": "%YOU%", "n": 0, "good": "ORE"}]}"""
          .replace("%YOU%", you)), sim, me)
    expect EscrowError:
      discard parseDecision(parseJson(
        """{"give": [{"to": "%YOU%", "n": 200, "good": "ORE"}]}"""
          .replace("%YOU%", you)), sim, me)
    expect EscrowError:
      discard parseDecision(parseJson(
        """{"give": [{"to": "%YOU%", "n": 1, "good": "SHEEP"}]}"""
          .replace("%YOU%", you)), sim, me)
    expect EscrowError:
      discard parseDecision(parseJson("""{"sign": [3]}"""), sim, me)

    ## Prose replies never reach the decision parser at all.
    let fenced = extractJsonObject(
      "Sure, here you go:\n```json\n{\"sign\": [\"C1\"]}\n```")
    check fenced{"sign"}.len == 1
    expect EscrowError:
      discard extractJsonObject("I will hold my stock this turn.")

    ## Anything AFTER the object is ignored: the object is the first
    ## balanced one, not everything up to the last brace. Round 9 lost six
    ## replies to "EOF expected" because a model signed off under its JSON.
    let chatty = extractJsonObject(
      "{\"sign\": [\"C4\"], \"say\": \"ore at 2.5\"}\n\nThat sale funds " &
      "two fills, and I keep {my timber} for the commission.")
    check chatty{"sign"}[0].getStr() == "C4"
    check chatty{"say"}.getStr() == "ore at 2.5"
    let twice = extractJsonObject(
      "{\"sign\": [\"C1\"]}\nOn reflection: {\"sign\": [\"C2\"]}")
    check twice{"sign"}[0].getStr() == "C1"
    ## Nested objects and braces inside strings are still one object.
    let nested = extractJsonObject(
      "{\"give\": [{\"to\": \"" & you & "\", \"n\": 1, \"good\": \"ORE\"}], " &
      "\"notes\": \"a { in a string, and a \\\" quote\"}  trailing words")
    check nested{"give"}.len == 1
    check nested{"notes"}.getStr().startsWith("a { in a string")
    ## An object that never closes is still no object at all.
    expect EscrowError:
      discard extractJsonObject("{\"sign\": [\"C1\"")

    ## The strict validator is what buys a seat its one retry.
    let illegal = parseDecision(parseJson(
      """{"sign": ["C9"]}"""), sim, me)
    check sim.validateMove(me, illegal).len > 0
    let unaffordable = parseDecision(parseJson(
      """{"give": [{"to": "%YOU%", "n": 99, "good": "TIMBER"}]}"""
        .replace("%YOU%", you)), sim, me)
    check sim.validateMove(me, unaffordable).len > 0
    ## And a seat may not give to itself.
    expect EscrowError:
      discard parseDecision(parseJson(
        """{"give": [{"to": "%ME%", "n": 1, "good": "ORE"}]}"""
          .replace("%ME%", sim.names[me])), sim, me)

    ## `talk: false` silences `say` at the parser, not just at the sim.
    let quiet = initSim(fixture(5, turns = 12, talk = false))
    let hushed = parseDecision(parseJson("""{"say": "hello"}"""), quiet,
      quiet.seatOfProfile[pMason])
    check hushed.say == ""

  test "17. an exhausted LLM retry is recorded as scripted on the move":
    ## The fallback has to reach the replay: phase 60 counts a seat played
    ## by the house baseline off `move.scripted`, and a credentialed
    ## episode whose replies keep failing is exactly the case the
    ## registration-time flag misses. An unreachable endpoint (a refused
    ## connection on the loopback discard port, no traffic off the box)
    ## fails both attempt 0 and the retry in milliseconds.
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:1")
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "not-a-real-token")
    let config = fixture(9, turns = 4)
    let client = newLlmClient(config)
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    ## Credentials are present, so this is NOT the disabled path test 15
    ## covers: every seat is registered LLM-driven and stays that way.
    check not client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    check seats.len == Seats
    let decisions = client.decideAll(sim, seats, @["", "", "", ""],
      @[skNone, skNone, skNone, skNone])
    check decisions.len == seats.len
    for index, seat in seats:
      let expected = scriptedAction(sim, seat, skTrader)
      check decisions[index].scripted
      check decisions[index].move.offer == expected.offer
      check decisions[index].move.signs == expected.signs
      check decisions[index].move.gives.len == expected.gives.len
      sim.applyMove(seat, decisions[index].move, decisions[index].scripted)
    var moves = 0
    for event in sim.events:
      if event.kind == evMove:
        moves.inc
        ## What the replay carries, and what phase 60 counts.
        check event.scripted
    check moves == Seats

  test "18. an accepted model reply is recorded as the model's own":
    ## The mirror of test 17, and the only test that reaches the line
    ## writing `scripted: false`: a stub endpoint returns ONE valid reply
    ## per open seat, so the batch is MIXED — seat 0 is registered as the
    ## scripted trader and never leaves the box, the other three are the
    ## model's own decisions — and the recorded move events must say so
    ## seat by seat, since phase 60 counts fallbacks off that flag.
    var listener = newSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1]
    let reply = $ %*{
      "content": [{"type": "text", "text":
        """{"say": "stub says hello", "notes": "stub notes"}"""}],
      "stop_reason": "end_turn"
    }
    stubServed = 0
    stubStop = false
    var stub: Thread[tuple[fd: SocketHandle, reply: string]]
    createThread(stub, stubServe, (fd: listener.getFd, reply: reply))

    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:" & $port.int)
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "stub-token")
    var config = fixture(11, turns = 4)
    config.llmTimeoutSeconds = 15
    let client = newLlmClient(config)
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    check not client.disabled

    var sim = initSim(config)
    let seats = sim.pendingSeats()
    check seats.len == Seats
    let decisions = client.decideAll(sim, seats, @["", "", "", ""],
      @[skTrader, skNone, skNone, skNone])
    stubStop = true
    joinThread(stub)
    listener.close()
    ## One request per model-driven seat, and no retry batch.
    check stubServed == Seats - 1
    check decisions.len == seats.len
    for index, seat in seats:
      if seat == 0:
        let expected = scriptedAction(sim, seat, skTrader)
        check decisions[index].scripted
        check decisions[index].move.offer == expected.offer
        check decisions[index].move.say.len == 0
      else:
        ## The reply parsed AND passed validateMove, so it is the seat's
        ## own move, not the house baseline's.
        check not decisions[index].scripted
        check decisions[index].move.say == "stub says hello"
        check decisions[index].move.notes == "stub notes"
      sim.applyMove(seat, decisions[index].move, decisions[index].scripted)
    var scriptedMoves = 0
    var modelMoves = 0
    for event in sim.events:
      if event.kind == evMove:
        if event.scripted: inc scriptedMoves else: inc modelMoves
    check scriptedMoves == 1
    check modelMoves == Seats - 1
