## Value types for Escrow. The `Sim` object lives here rather than in
## `sim.nim` for one reason: `dsl.nim` parses a contract against the live
## floor (`parseContract(text, sim, proposer)`) and `sim.nim` calls the
## parser, so the two would import each other. Both import this module
## instead; `sim.nim` re-exports everything, so `escrow/sim` still hands a
## caller the whole vocabulary.

import std/[json, strutils]

const Seats* = 4
  ## Escrow seats exactly four cogs; the whole floor is sized to it.

type
  EscrowError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    turns*: int           ## decision turns in the episode
    talk*: bool           ## seats may broadcast a short public message
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Good* = enum
    gOre = "ORE"
    gGrain = "GRAIN"
    gTimber = "TIMBER"
    gHearts = "HEARTS"

  Bundle* = array[Good, int]

  Profile* = enum
    pMason = "Mason"
    pFarmer = "Farmer"
    pForester = "Forester"
    pFactor = "Factor"

  SeatState* = object
    ## One booth on the trading floor, as seen at the start of a turn.
    stock*: Bundle      ## FREE stock, hearts included
    escrowed*: Bundle   ## locked into live contracts, unusable
    fills*: int         ## commission copies filled so far
    heartsEarned*: int  ## hearts minted by commissions (never transfers)
    signedCount*: int   ## contracts this seat was party to that reached signed
    forfeits*: int      ## settlements that sent BOTH escrows to the other side

  Payout* = enum
    poSwap = "SWAP"
    poKeep = "KEEP"
    poProposer = "PROPOSER"
    poAcceptor = "ACCEPTOR"

  CondKind* = enum
    ckAlways = "ALWAYS"
    ckHolds = "HOLDS"
    ckPaid = "PAID"

  Condition* = object
    kind*: CondKind
    negated*: bool
    who*: int           ## seat the atom names; -1 for ALWAYS
    n*: int
    good*: Good

  ContractStatus* = enum
    csOffered = "offered"
    csSigned = "signed"
    csSettled = "settled"
    csExpired = "expired"
    csVoid = "void"

  Contract* = object
    id*: string           ## "C1", "C2", …
    proposer*: int
    acceptor*: int        ## the addressee; also the signer once signed
    lock*: Bundle         ## the proposer's stake, in escrow from registration
    ask*: Bundle          ## the acceptor's stake, in escrow from signature
    due*: int
    cond*: Condition
    thenPay*: Payout
    elsePay*: Payout
    status*: ContractStatus
    postedTurn*: int
    signedTurn*: int      ## -1 until signed
    text*: string         ## the normalized seven-line DSL

  Transfer* = object
    ## An open `give`. The PAID condition reads exactly this log.
    turn*: int
    sender*: int
    receiver*: int
    good*: Good
    n*: int

  EventKind* = enum
    evStart = "start"
    evTurn = "turn"
    evMove = "move"
    evOffer = "offer"
    evSign = "sign"
    evGive = "give"
    evReject = "reject"
    evExpire = "expire"
    evSettle = "settle"
    evFill = "fill"
    evEnd = "end"

  GiveOrder* = object
    to*: int
    n*: int
    good*: Good

  Move* = object
    ## One seat's whole decision for a turn.
    offer*: string        ## raw DSL text, "" for none
    gives*: seq[GiveOrder]
    signs*: seq[string]   ## contract ids
    say*: string
    notes*: string

  PayoutLeg* = object
    to*: int
    n*: int
    good*: Good

  GameEvent* = object
    kind*: EventKind
    turn*: int           ## turn/move/…: the turn; end: turns played; start: -1
    seat*: int           ## the acting seat; -1 when there is none
    scripted*: bool      ## move: decided by a scripted baseline
    ok*: bool            ## sign/give: whether it applied
    text*: string        ## move: the seat's notes; end: reason; else: a message
    say*: string         ## move: the seat's public message
    offer*: string       ## move: the raw DSL text the seat submitted
    gives*: seq[GiveOrder]  ## move: what the seat asked to give
    signs*: seq[string]     ## move: contract ids the seat asked to sign
    id*: string          ## offer/sign/expire/settle: the contract id
    target*: int         ## offer: addressee; give: recipient
    n*: int              ## give: units; fill: copies filled
    good*: Good          ## give: the good
    dsl*: string         ## offer: the normalized contract text
    lock*: Bundle        ## offer: the proposer's stake
    ask*: Bundle         ## offer: the acceptor's stake
    due*: int            ## offer: the settlement turn
    cond*: string        ## offer/settle: the rendered condition
    thenPay*: Payout     ## offer
    elsePay*: Payout     ## offer
    held*: bool          ## settle: the condition's truth value
    branch*: string      ## settle: "then" | "else" | "horizon"
    payout*: Payout      ## settle: the payout taken
    legs*: seq[PayoutLeg]  ## settle: every transfer the payout caused
    hearts*: int         ## fill: hearts credited
    seats*: seq[SeatState] ## turn: the four booths, by seat
    board*: seq[Contract]  ## turn: the live contracts

  Phase* = enum
    phMoves = "moves"     ## the floor is waiting on this turn's decisions
    phDone = "done"

  TurnRecord* = object
    seats*: array[Seats, SeatState]
    moves*: array[Seats, Move]

  Sim* = object
    config*: GameConfig
    names*: seq[string]                 ## anonymous table aliases per seat
    profileOf*: array[Seats, Profile]
    seatOfProfile*: array[Profile, int]
    turn*: int                          ## the live turn
    seats*: array[Seats, SeatState]
    contracts*: seq[Contract]
    nextId*: int
    transfers*: seq[Transfer]           ## every open give, ever
    moves*: array[Seats, Move]          ## live turn
    moveIn*: array[Seats, bool]         ## false = still pending
    says*: array[Seats, string]         ## live turn
    heard*: array[Seats, string]        ## last turn's says
    notes*: seq[string]                 ## latest private notes per seat
    history*: seq[TurnRecord]
    turnsPlayed*: int
    phase*: Phase
    done*: bool
    reason*: string                     ## "complete" | "deadline"
    events*: seq[GameEvent]

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    turns: 16,
    talk: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 1100,
    llmTimeoutSeconds: 60
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(EscrowError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("turns"):
    config.turns = node["turns"].getInt()
  if node.hasKey("talk"):
    config.talk = node["talk"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.turns < 4:
    raise newException(EscrowError, "turns must be at least 4")
