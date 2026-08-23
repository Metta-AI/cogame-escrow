## Claude-backed decision making for Escrow. Each seat's policy is just a
## prompt: the game server composes the seat's view (its booth, the whole
## public floor, the escrow board, the ledger, the messages, its notes)
## plus that seat's prompt and asks Claude what it gives, offers, signs
## and says.
##
## Decisions within a turn are simultaneous by rule, so the four requests
## go out as ONE parallel batch (curly.makeRequests); invalid replies are
## retried as a smaller batch carrying the exact error, and anything still
## failing falls back to the scripted `trader` baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[algorithm, json, math, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## Turns of public ledger a seat is shown.
  LedgerTurns = 6
  ## The scripted baseline's house price table. Flat across the three
  ## goods, which is what makes an equal-count swap exactly fair and an
  ## unequal one obviously not.
  HousePrice*: array[Good, int] = [gOre: 3, gGrain: 3, gTimber: 3, gHearts: 1]
  ## Units the `trader` baseline puts on the table in one contract.
  TradeUnits* = 4

type
  ScriptKind* = enum
    skNone = "none"
    skTrader = "trader"
    skHoarder = "hoarder"

  Decision* = Move

  SignPick = tuple[gain: int, index: int]

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"trader" play the trading
  ## baseline, "hoarder"/"autarky" the do-nothing foil, anything else
  ## nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "trader": skTrader
  of "hoarder", "autarky": skHoarder
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "escrow llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "escrow llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "escrow llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "escrow llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "escrow llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc bundleValue*(bundle: Bundle): int =
  for good in Good:
    result += bundle[good] * HousePrice[good]

proc twoFillNeed*(sim: Sim, seat: int): Bundle =
  for good in Good:
    result[good] = MaxFills * Commission[sim.profileOf[seat]][good]

proc byGain(a, b: SignPick): int =
  ## Best value first; contract-id order breaks every tie, so the bot is
  ## fully deterministic.
  if a.gain != b.gain: b.gain - a.gain else: a.index - b.index

proc traderAction*(sim: Sim, seat: int): Decision =
  ## The sensible partner, and the universal fallback. Deterministic, and
  ## legal BY CONSTRUCTION: it only signs offers addressed to it that it
  ## can pay, and it only posts an offer when both it and the addressee
  ## hold zero live contracts — which bounds the live count below MaxLive
  ## no matter what the other three seats do in the same turn.
  var stock = sim.seats[seat].stock

  ## Sign: best-valued affordable offers addressed to us, up to MaxSigns.
  var candidates: seq[SignPick]
  for index, contract in sim.contracts:
    if contract.status != csOffered or contract.acceptor != seat:
      continue
    if contract.postedTurn != sim.turn - 1:
      continue
    if contract.thenPay notin {poSwap, poAcceptor}:
      continue
    var received = contract.lock
    if contract.thenPay == poAcceptor:
      for good in Good:
        received[good] += contract.ask[good]
    let gain = bundleValue(received) - bundleValue(contract.ask)
    if gain < 0:
      continue
    candidates.add((gain: gain, index: index))
  candidates.sort(byGain)
  for candidate in candidates:
    if result.signs.len >= MaxSigns:
      break
    let ask = sim.contracts[candidate.index].ask
    var affordable = true
    for good in Good:
      if stock[good] < ask[good]:
        affordable = false
    if not affordable:
      continue
    for good in Good:
      stock[good] -= ask[good]
    result.signs.add(sim.contracts[candidate.index].id)

  ## Offer: our largest surplus for our largest deficit, priced 1:1 at the
  ## house table. Hearts are never the surplus — spending the score to buy
  ## inputs is a strategy, not a baseline.
  if sim.turn + 1 > sim.config.turns - 1:
    return
  if sim.liveContracts(seat) != 0:
    return
  let need = sim.twoFillNeed(seat)
  var surplus = gOre
  var surplusExcess = 0
  var deficit = gOre
  var deficitShort = 0
  for good in [gOre, gGrain, gTimber]:
    let excess = stock[good] - need[good]
    if excess > surplusExcess:
      surplusExcess = excess
      surplus = good
    let short = need[good] - stock[good]
    if short > deficitShort:
      deficitShort = short
      deficit = good
  if surplusExcess <= 0 or deficitShort <= 0:
    return
  var target = -1
  var bestStock = 0
  for other in 0 ..< Seats:
    if other == seat or sim.liveContracts(other) != 0:
      continue
    if sim.seats[other].stock[deficit] > bestStock:
      bestStock = sim.seats[other].stock[deficit]
      target = other
  if target < 0:
    return
  let units = min(TradeUnits, surplusExcess)
  var lock: Bundle
  lock[surplus] = units
  var ask: Bundle
  ask[deficit] = units
  result.offer = @[
    "OFFER " & sim.names[target],
    "LOCK " & renderBundle(lock),
    "ASK " & renderBundle(ask),
    "DUE " & $(sim.turn + 1),
    "IF ALWAYS",
    "THEN SWAP",
    "ELSE KEEP"
  ].join("\n")

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`. Always legal; never talks or notes.
  ## `hoarder` produces, fills commissions and does nothing else — the
  ## autarky floor any trading policy has to beat.
  case kind
  of skHoarder: Decision()
  else: traderAction(sim, seat)

# ---- Prompt building --------------------------------------------------------

proc goodsLine(bundle: Bundle): string =
  $bundle[gOre] & " ore, " & $bundle[gGrain] & " grain, " &
    $bundle[gTimber] & " timber"

proc floorTable(sim: Sim): string =
  var lines: seq[string]
  lines.add("cog | profile | produces/turn | commission (consumes -> pays) | " &
    "free ore/grain/timber | free hearts | escrowed ore/grain/timber/hearts")
  for seat in 0 ..< Seats:
    let profile = sim.profileOf[seat]
    let state = sim.seats[seat]
    lines.add(sim.names[seat] & " | " & $profile & " | " &
      goodsLine(Production[profile]) & " | " &
      renderBundle(Commission[profile]) & " -> " &
      $CommissionPay[profile] & " hearts | " &
      $state.stock[gOre] & "/" & $state.stock[gGrain] & "/" &
      $state.stock[gTimber] & " | " & $state.stock[gHearts] & " | " &
      $state.escrowed[gOre] & "/" & $state.escrowed[gGrain] & "/" &
      $state.escrowed[gTimber] & "/" & $state.escrowed[gHearts])
  lines.join("\n")

proc escrowBoard(sim: Sim): string =
  var lines: seq[string]
  for contract in sim.contracts:
    if contract.status notin {csOffered, csSigned}:
      continue
    lines.add(contract.id & " [" & $contract.status & "] " &
      sim.names[contract.proposer] & " -> " & sim.names[contract.acceptor] &
      ": LOCK " & renderBundle(contract.lock) & " / ASK " &
      renderBundle(contract.ask) & " / DUE " & $contract.due & " (in " &
      $(contract.due - sim.turn) & ") / IF " &
      renderCondition(sim, contract.cond) & " / THEN " & $contract.thenPay &
      " / ELSE " & $contract.elsePay)
  if lines.len == 0:
    return "(the board is empty)"
  lines.join("\n")

proc describeEvent(sim: Sim, event: GameEvent): string =
  let who =
    if event.seat >= 0 and event.seat < Seats: sim.names[event.seat] else: "?"
  case event.kind
  of evOffer:
    who & " offers " & event.id & " to " &
      (if event.target >= 0: sim.names[event.target] else: "?") & ": LOCK " &
      renderBundle(event.lock) & " for ASK " & renderBundle(event.ask) &
      ", due turn " & $event.due & ", IF " & event.cond & " THEN " &
      $event.thenPay & " ELSE " & $event.elsePay
  of evSign:
    if event.ok: who & " signs " & event.id & " — escrow sealed"
    else: who & " fails to sign " & event.id & " (" & event.text & ")"
  of evGive:
    if event.ok:
      who & " gives " & (if event.target >= 0: sim.names[event.target] else: "?") &
        " " & $event.n & " " & ($event.good).toLowerAscii()
    else:
      who & " fails to give (" & event.text & ")"
  of evReject:
    who & "'s offer was refused: " & event.text
  of evExpire:
    event.id & " expires unsigned — the stake goes back to " & who
  of evSettle:
    var legs: seq[string]
    for leg in event.legs:
      legs.add(sim.names[leg.to] & " +" & $leg.n & " " &
        ($leg.good).toLowerAscii())
    event.id & " settles: " & event.cond & " -> " &
      (if event.branch == "horizon": "HORIZON"
       elif event.held: "TRUE" else: "FALSE") & " -> " & $event.payout &
      (if legs.len > 0: " (" & legs.join(", ") & ")" else: "")
  of evFill:
    who & " fills " & $event.n & " commission" &
      (if event.n == 1: "" else: "s") & " (+" & $event.hearts & " hearts)"
  else:
    ""

proc ledger(sim: Sim): string =
  var lines: seq[string]
  var lastTurn = -2
  for event in sim.events:
    if event.turn < sim.turn - LedgerTurns:
      continue
    let text = sim.describeEvent(event)
    if text.len == 0:
      continue
    if event.turn != lastTurn:
      lines.add("-- turn " & $event.turn)
      lastTurn = event.turn
    lines.add("  " & text)
  if lines.len == 0:
    return "(nothing has happened yet)"
  lines.join("\n")

proc heardBlock(sim: Sim, seat: int): string =
  if not sim.config.talk:
    return ""
  var lines: seq[string]
  for other in 0 ..< Seats:
    if other != seat and sim.heard[other].len > 0:
      lines.add(sim.names[other] & " said: \"" & sim.heard[other] & "\"")
  "WHAT THE FLOOR SAID LAST TURN (public, non-binding):\n" &
    (if lines.len > 0: lines.join("\n") else: "(nobody spoke)") & "\n\n"

proc systemPrompt*(sim: Sim, seat: int): string =
  let profile = sim.profileOf[seat]
  result = "You are " & sim.names[seat] & ", the " &
    ($profile).toUpperAscii() & " on a four-cog trading floor. Three goods " &
    "(ORE, GRAIN, TIMBER), one currency (HEARTS), and a contract language " &
    "the game itself executes.\n"
  result.add("""
Rules:
- Every turn you produce your profile's goods automatically, and at the end
  of the turn you automatically fill up to 2 copies of your commission from
  free stock (goods in, hearts out). Filling commissions is the ONLY source
  of new hearts. Everything else moves hearts between cogs.
- Your SCORE is your free hearts at the horizon. HIGHER IS BETTER. Leftover
  goods are worth NOTHING, so convert before the end.
- Comparative advantage is the whole game: your own bulk good is useless to
  your own commission and is exactly what somebody else needs. The implied
  price band is 2.0-2.5 hearts per unit.
- The floor is OPEN OUTCRY. Every cog's profile, free stock, escrowed stock
  and every live contract is public. Nothing is hidden except other cogs'
  private notes.
- A turn resolves in this order: (1) production, (2) everyone decides at the
  same time, (3) signings, (4) gives, (5) new offers registered, (6) offers
  posted last turn expire, (7) contracts due this turn settle, (8)
  commissions fill, (9) tally.
- CONTRACTS ARE PRE-FUNDED, SO BREACH IS IMPOSSIBLE. Posting an offer moves
  your LOCK bundle out of your free stock into escrow immediately; signing
  moves the acceptor's ASK bundle into escrow. Settlement only redistributes
  what is already locked. Escrowed stock cannot be given away, cannot fill a
  commission, and DOES NOT COUNT toward a HOLDS condition - that is the
  loophole: locking your own stock in an unrelated contract makes someone's
  "HOLDS you 6 TIMBER" clause read false.
- An offer lives exactly one turn: posted on turn t, signable only on t+1,
  then it expires and the stake comes back.

THE CONTRACT LANGUAGE - exactly seven lines, in this order, at most """ &
    $MaxOfferChars & """ characters:
  OFFER <cog>
  LOCK  <bundle>
  ASK   <bundle>
  DUE   <turn>
  IF    <condition>
  THEN  <payout>
  ELSE  <payout>
  <bundle>    = NOTHING, or 1-3 terms like "5 ORE" or "5 ORE + 12 HEARTS"
                (each count 1-""" & $MaxUnits & """, each good at most once)
  <condition> = ALWAYS | [NOT] HOLDS <cog> <n> <good> | [NOT] PAID <cog> <n> <good>
  <payout>    = SWAP (each side takes the other's escrow) | KEEP (each takes
                its own back) | PROPOSER (proposer takes both) | ACCEPTOR
                (acceptor takes both)
  HOLDS reads FREE stock at settlement. PAID counts units handed over by open
  `give` to the other party since the contract was signed, and may only name
  one of the two parties.
  DUE must be between the next turn and """ & $DueWindow & """ turns ahead,
  and before the horizon. You may be party to at most """ & $MaxLive & """
  live contracts (offered or signed, either role).

WORKED EXAMPLES (one statement per line in your reply, separated by \n):
  A funded sale, settled next turn:
    OFFER Gizmo / LOCK 5 ORE / ASK 12 HEARTS / DUE 8 / IF ALWAYS / THEN SWAP / ELSE KEEP
  A performance bond - Gizmo only gets my ore if it has actually shipped me timber:
    OFFER Gizmo / LOCK 5 ORE / ASK 4 TIMBER / DUE 9 / IF PAID Gizmo 4 TIMBER / THEN SWAP / ELSE PROPOSER
  An insurance clause - if Ratchet is still short of grain at turn 11, the escrow is mine:
    OFFER Ratchet / LOCK 6 HEARTS / ASK 6 HEARTS / DUE 11 / IF NOT HOLDS Ratchet 4 GRAIN / THEN PROPOSER / ELSE KEEP
  (The "/" above is presentation only. Your `offer` string uses real newlines.)
""")
  if sim.config.talk:
    result.add("- You may SAY one short public message (max " & $MaxSayLen &
      " characters) each turn; ALL three other cogs read it next turn. It " &
      "is not binding and may or may not be honest.\n")
  result.add("- Your notes are private to you and fed back every turn.\n")
  result.add("""
OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }.""")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let profile = sim.profileOf[seat]
  let state = sim.seats[seat]
  result.add("Turn " & $sim.turn & " of " & $sim.config.turns & ". You are " &
    sim.names[seat] & ", the " & ($profile).toUpperAscii() & ".\n\n")
  result.add("YOU PRODUCE " & goodsLine(Production[profile]) &
    " every turn. YOUR COMMISSION consumes " &
    renderBundle(Commission[profile]) & " and pays " &
    $CommissionPay[profile] & " hearts, up to " & $MaxFills &
    " copies a turn.\n")
  result.add("YOUR FREE STOCK: " & goodsLine(state.stock) & ", " &
    $state.stock[gHearts] & " hearts. YOUR ESCROWED STOCK: " &
    goodsLine(state.escrowed) & ", " & $state.escrowed[gHearts] &
    " hearts (unusable until settlement).\n")
  result.add("Commissions filled so far: " & $state.fills & ".\n\n")
  result.add("THE FLOOR:\n" & sim.floorTable() & "\n\n")
  result.add("THE ESCROW BOARD:\n" & sim.escrowBoard() & "\n\n")
  result.add("RECENT LEDGER:\n" & sim.ledger() & "\n\n")
  result.add(sim.heardBlock(seat))
  result.add("YOUR NOTES FROM EARLIER TURNS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY a JSON object of the form {\"give\": [{\"to\": " &
    "\"<cog>\", \"n\": 4, \"good\": \"ORE\"}], \"offer\": \"OFFER <cog>\\n" &
    "LOCK ...\", \"sign\": [\"C3\"]" &
    (if sim.config.talk: ", \"say\": \"…\"" else: "") &
    ", \"notes\": \"…\"} — at most " & $MaxGives & " gives (n 1.." &
    $MaxUnits & "), at most one offer (" & $MaxOfferChars &
    " characters), at most " & $MaxSigns & " signings" &
    (if sim.config.talk: ", say at most " & $MaxSayLen &
      " characters (or \"\")" else: "") &
    ", notes at most " & $MaxNotesLen &
    " characters. Every field is optional; {} means you pass this turn.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model
    ## sent instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(EscrowError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or an EscrowError describing why there
  ## is none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(EscrowError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(EscrowError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(EscrowError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(EscrowError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(EscrowError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(EscrowError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(EscrowError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

# ---- Reply parsing ----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. Never
  ## a byte slice: a cut through a multi-byte character would put invalid
  ## UTF-8 into the replay and break its JSON.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc wholeNumber(node: JsonNode, what: string): int =
  ## An integer, a numeric string, or a float (rounded).
  if node.isNil:
    raise newException(EscrowError, what & " is missing")
  case node.kind
  of JInt:
    node.getInt()
  of JFloat:
    int(round(node.getFloat()))
  of JString:
    let text = node.getStr().strip()
    try:
      int(round(parseFloat(text)))
    except ValueError:
      raise newException(EscrowError, what & " is not a number: " & text)
  else:
    raise newException(EscrowError, what & " must be a number: " & $node)

proc parseDecision*(payload: JsonNode, sim: Sim, seat: int): Decision =
  ## Tolerant by design: missing fields mean "no action" and `{}` is a
  ## legal reply meaning "pass". A MALFORMED entry, though, invalidates the
  ## whole reply so the retry can quote the exact problem.
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"say"}.getStr().replace("\n", " "), MaxSayLen)
  if not sim.config.talk:
    result.say = ""
  result.offer = clip(payload{"offer"}.getStr(), MaxOfferChars)
  let signs = payload{"sign"}
  if not signs.isNil and signs.kind == JArray:
    for entry in signs:
      if result.signs.len >= MaxSigns:
        break   ## entries past the cap are dropped, not fatal
      if entry.kind != JString:
        raise newException(EscrowError, "each sign entry is a contract id")
      result.signs.add(entry.getStr().strip().toUpperAscii())
  let gives = payload{"give"}
  if not gives.isNil and gives.kind == JArray:
    for entry in gives:
      if result.gives.len >= MaxGives:
        break   ## entries past the cap are dropped, not fatal
      if entry.kind != JObject:
        raise newException(EscrowError, "each give is {to, n, good}")
      var order: GiveOrder
      let to = entry{"to"}
      if to.isNil:
        raise newException(EscrowError, "a give needs a \"to\" cog")
      order.to =
        if to.kind == JInt: to.getInt()
        else: sim.seatOfName(to.getStr())
      if order.to < 0 or order.to >= Seats:
        raise newException(EscrowError,
          "\"" & to.getStr() & "\" is not a cog at this table")
      if order.to == seat:
        raise newException(EscrowError, "you cannot give to yourself")
      order.n = wholeNumber(entry{"n"}, "a give's n")
      if order.n < 1 or order.n > MaxUnits:
        raise newException(EscrowError,
          "a give is 1.." & $MaxUnits & " units, got " & $order.n)
      let good = entry{"good"}
      if good.isNil or good.kind != JString:
        raise newException(EscrowError,
          "a give needs a good: ORE, GRAIN, TIMBER or HEARTS")
      try:
        order.good = parseEnum[Good](good.getStr().strip().toUpperAscii())
      except ValueError:
        raise newException(EscrowError,
          "\"" & good.getStr() & "\" is not ORE, GRAIN, TIMBER or HEARTS")
      result.gives.add(order)

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the scripted `trader` baseline so the episode always
  ## advances. `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  var hints = newSeq[string](seats.len)
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skTrader else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    ## Decisions within a turn are simultaneous by rule, so every pending
    ## seat goes out in ONE parallel batch: 16 turns is 16 round trips,
    ## not 64.
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was invalid: " & hints[index] &
          ". Respond with ONLY the requested JSON object.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let decision = parseDecision(extractJsonObject(text), sim, seat)
        ## Reject illegal replies here so the retry carries the hint. The
        ## strict validator walks the sim's own resolution order on a copy
        ## of this seat's stock.
        let problem = sim.validateMove(seat, decision)
        if problem.len > 0:
          raise newException(EscrowError, problem)
        result[index] = decision
      except CatchableError as error:
        echo "escrow llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        hints[index] = cleanText(error.msg, 300)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "escrow llm: seat ", seat, " falling back to the trader baseline"
    result[index] = scriptedAction(sim, seat, skTrader)
