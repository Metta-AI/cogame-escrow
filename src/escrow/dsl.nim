## The Escrow contract language: seven lines the game itself executes.
##
## A contract is pre-funded at signature — the proposer's LOCK leaves its
## free stock when the offer is posted and the acceptor's ASK when it
## signs, both into an escrow the sim owns. Settlement only redistributes
## what is already locked, so BREACH IS IMPOSSIBLE; the skill is drafting,
## pricing, and spotting loopholes in other people's clauses.
##
##   OFFER <cog>
##   LOCK  <bundle>
##   ASK   <bundle>
##   DUE   <turn>
##   IF    <condition>
##   THEN  <payout>
##   ELSE  <payout>
##
## Pure: no IO, no LLM. The server, the tests and the wasm replay viewer
## all parse with this module.

# Only runeLen is taken from unicode: a bare `import unicode` alongside
# strutils makes every splitWhitespace call ambiguous.
import std/strutils, types
from std/unicode import runeLen

export types

const
  MaxUnits* = 99
    ## Largest `n` in any bundle term or condition atom.
  MaxOfferChars* = 240
    ## Longest contract text a seat may submit, in characters (runes).
  DueWindow* = 6
    ## DUE may be at most this many turns after the turn the offer is posted.
  MaxLive* = 4
    ## Live contracts (offered + signed, either role) a seat may be party to.
  MaxTerms* = 3
    ## Terms in one bundle; each good may appear at most once.
  Keywords* = ["OFFER", "LOCK", "ASK", "DUE", "IF", "THEN", "ELSE"]

type
  ParseResult* = object
    ok*: bool
    contract*: Contract   ## valid only when `ok`
    reason*: string       ## machine reason code, "" when ok
    message*: string      ## human explanation, "" when ok

# ---- Rendering --------------------------------------------------------------

proc renderBundle*(bundle: Bundle): string =
  ## `NOTHING`, or `5 ORE + 12 HEARTS` in Good order.
  var terms: seq[string]
  for good in Good:
    if bundle[good] > 0:
      terms.add($bundle[good] & " " & $good)
  if terms.len == 0: "NOTHING" else: terms.join(" + ")

proc bundleEmpty*(bundle: Bundle): bool =
  for good in Good:
    if bundle[good] != 0:
      return false
  true

proc renderCondition*(sim: Sim, cond: Condition): string =
  case cond.kind
  of ckAlways:
    "ALWAYS"
  else:
    let who =
      if cond.who >= 0 and cond.who < sim.names.len: sim.names[cond.who]
      else: "Seat " & $cond.who
    (if cond.negated: "NOT " else: "") & $cond.kind & " " & who & " " &
      $cond.n & " " & $cond.good

proc renderContract*(sim: Sim, contract: Contract): string =
  ## The normalized seven lines: what goes on the board, into the prompt
  ## and into the replay. Keywords upper-case; cog aliases keep their own
  ## capitalisation so a spectator reads a name, not a shout.
  let target =
    if contract.acceptor >= 0 and contract.acceptor < sim.names.len:
      sim.names[contract.acceptor]
    else: "Seat " & $contract.acceptor
  @[
    "OFFER " & target,
    "LOCK " & renderBundle(contract.lock),
    "ASK " & renderBundle(contract.ask),
    "DUE " & $contract.due,
    "IF " & renderCondition(sim, contract.cond),
    "THEN " & $contract.thenPay,
    "ELSE " & $contract.elsePay
  ].join("\n")

# ---- Queries ----------------------------------------------------------------

proc liveContracts*(sim: Sim, seat: int): int =
  ## Contracts this seat is party to that are still offered or signed.
  for contract in sim.contracts:
    if contract.status in {csOffered, csSigned} and
        (contract.proposer == seat or contract.acceptor == seat):
      inc result

proc seatOfName*(sim: Sim, name: string): int =
  ## Case-insensitive alias lookup; -1 when the name is not at the table.
  let wanted = name.strip().toLowerAscii()
  for seat, alias in sim.names:
    if alias.toLowerAscii() == wanted:
      return seat
  -1

# ---- Parsing ----------------------------------------------------------------

proc collapse(text: string): string =
  ## Whitespace runs inside a line become one space.
  text.splitWhitespace().join(" ")

proc firstWord(line: string): string =
  let parts = line.splitWhitespace()
  if parts.len == 0: "" else: parts[0].toUpperAscii()

proc normalizeOfferText*(text: string): string =
  ## Pre-parse hygiene, never semantics: the contract is the run of lines
  ## from the OFFER line to the ELSE line, so a model that writes the
  ## addressee's alias on a line of its own above the contract, or a word
  ## of explanation under it, is still understood. Nothing inside those
  ## lines is touched, and text with no OFFER line at all comes back
  ## unchanged so it is rejected exactly as before.
  let lines = text.splitLines()
  var first = -1
  for index, line in lines:
    if firstWord(line) == "OFFER":
      first = index
      break
  if first < 0:
    return text
  var last = lines.high
  for index in first .. lines.high:
    if firstWord(lines[index]) == "ELSE":
      last = index
      break
  lines[first .. last].join("\n")

proc parseCount(token: string, value: var int): bool =
  try:
    value = parseInt(token)
  except ValueError:
    return false
  value >= 1 and value <= MaxUnits

proc parseGood(token: string, good: var Good): bool =
  case token.toUpperAscii()
  of "ORE": good = gOre
  of "GRAIN": good = gGrain
  of "TIMBER": good = gTimber
  of "HEARTS", "HEART": good = gHearts
  else: return false
  true

proc parseBundle*(text: string, bundle: var Bundle): bool =
  ## `NOTHING` or 1..3 `<n> <good>` terms joined by `+`, each good once.
  for good in Good:
    bundle[good] = 0
  let body = collapse(text)
  if body.len == 0:
    return false
  if body.toUpperAscii() == "NOTHING":
    return true
  let terms = body.split('+')
  if terms.len < 1 or terms.len > MaxTerms:
    return false
  var seen: set[Good]
  for term in terms:
    let parts = term.splitWhitespace()
    if parts.len != 2:
      return false
    var n = 0
    var good: Good
    if not parseCount(parts[0], n):
      return false
    if not parseGood(parts[1], good):
      return false
    if good in seen:
      return false
    seen.incl(good)
    bundle[good] = n
  true

proc parsePayout(token: string, payout: var Payout): bool =
  case token.toUpperAscii()
  of "SWAP": payout = poSwap
  of "KEEP": payout = poKeep
  of "PROPOSER": payout = poProposer
  of "ACCEPTOR": payout = poAcceptor
  else: return false
  true

proc parseCondition(sim: Sim, text: string, cond: var Condition): bool =
  ## `ALWAYS` | `[NOT] HOLDS <cog> <n> <good>` | `[NOT] PAID <cog> <n> <good>`
  var tokens = collapse(text).splitWhitespace()
  if tokens.len == 0:
    return false
  cond = Condition(kind: ckAlways, negated: false, who: -1, n: 0, good: gOre)
  if tokens[0].toUpperAscii() == "NOT":
    cond.negated = true
    tokens = tokens[1 .. ^1]
  if tokens.len == 0:
    return false
  case tokens[0].toUpperAscii()
  of "ALWAYS":
    ## `NOT ALWAYS` is never true and never useful; reject it as a typo.
    return tokens.len == 1 and not cond.negated
  of "HOLDS": cond.kind = ckHolds
  of "PAID": cond.kind = ckPaid
  else: return false
  if tokens.len != 4:
    return false
  cond.who = sim.seatOfName(tokens[1])
  if cond.who < 0:
    return false
  if not parseCount(tokens[2], cond.n):
    return false
  if not parseGood(tokens[3], cond.good):
    return false
  true

proc failure(reason, message: string): ParseResult =
  ParseResult(ok: false, reason: reason, message: message)

proc parseContract*(text: string, sim: Sim, proposer: int): ParseResult =
  ## Parses AND validates one offer against the floor as it stands.
  ## Every rejection carries a machine reason code so the retry batch can
  ## quote the exact problem back to the model. The submitted text is
  ## measured before `normalizeOfferText` trims it, so padding an offer
  ## out past the cap is still `too_long`.
  if text.strip().len == 0:
    return failure("syntax", "the offer is empty")
  if text.runeLen > MaxOfferChars:
    return failure("too_long",
      "a contract is at most " & $MaxOfferChars & " characters")
  var lines: seq[string]
  for raw in normalizeOfferText(text).splitLines():
    let line = collapse(raw)
    if line.len > 0:
      lines.add(line)
  if lines.len != Keywords.len:
    return failure("syntax", "a contract is exactly " & $Keywords.len &
      " lines: " & Keywords.join(", ") & "; got " & $lines.len)
  var fields: array[Keywords.len, string]
  for index, line in lines:
    let space = line.find(' ')
    let keyword = (if space < 0: line else: line[0 ..< space]).toUpperAscii()
    if keyword != Keywords[index]:
      return failure("syntax", "line " & $(index + 1) & " must start with " &
        Keywords[index] & ", got \"" & keyword & "\"")
    fields[index] = (if space < 0: "" else: line[space + 1 .. ^1]).strip()

  var contract = Contract(
    id: "",
    proposer: proposer,
    acceptor: -1,
    due: -1,
    status: csOffered,
    postedTurn: sim.turn,
    signedTurn: -1
  )

  ## 2. OFFER names a table alias other than the proposer.
  contract.acceptor = sim.seatOfName(fields[0])
  if contract.acceptor < 0:
    return failure("bad_target", "\"" & fields[0] & "\" is not at this table")
  if contract.acceptor == proposer:
    return failure("bad_target", "you cannot offer a contract to yourself")

  ## 3. Bundles.
  if not parseBundle(fields[1], contract.lock):
    return failure("bad_bundle", "LOCK must be NOTHING or 1-" & $MaxTerms &
      " terms like \"5 ORE + 12 HEARTS\", each count 1.." & $MaxUnits)
  if not parseBundle(fields[2], contract.ask):
    return failure("bad_bundle", "ASK must be NOTHING or 1-" & $MaxTerms &
      " terms like \"5 ORE + 12 HEARTS\", each count 1.." & $MaxUnits)
  ## 4. Not both NOTHING.
  if bundleEmpty(contract.lock) and bundleEmpty(contract.ask):
    return failure("bad_bundle", "LOCK and ASK cannot both be NOTHING")

  ## 5. DUE inside the window and inside the horizon.
  try:
    contract.due = parseInt(fields[3])
  except ValueError:
    return failure("bad_due", "DUE must be a turn number")
  let earliest = sim.turn + 1
  let latest = min(sim.turn + DueWindow, sim.config.turns - 1)
  if latest < earliest:
    return failure("bad_due", "no legal DUE turn remains before the horizon")
  if contract.due < earliest or contract.due > latest:
    return failure("bad_due", "DUE must be between " & $earliest & " and " &
      $latest)

  ## 6. Condition.
  if not parseCondition(sim, fields[4], contract.cond):
    return failure("bad_condition", "IF must be ALWAYS, [NOT] HOLDS " &
      "<cog> <n> <good>, or [NOT] PAID <cog> <n> <good>, naming a cog at " &
      "this table")
  if contract.cond.kind == ckPaid and
      contract.cond.who != proposer and contract.cond.who != contract.acceptor:
    return failure("bad_condition",
      "PAID may only name one of the two parties to the contract")

  ## 7. Payouts.
  if not parsePayout(fields[5], contract.thenPay):
    return failure("bad_payout", "THEN must be SWAP, KEEP, PROPOSER or ACCEPTOR")
  if not parsePayout(fields[6], contract.elsePay):
    return failure("bad_payout", "ELSE must be SWAP, KEEP, PROPOSER or ACCEPTOR")

  ## 8. The proposer funds its own stake right now, out of FREE stock.
  for good in Good:
    if contract.lock[good] > sim.seats[proposer].stock[good]:
      return failure("unfunded", "you hold " &
        $sim.seats[proposer].stock[good] & " free " & $good & " but LOCK " &
        $contract.lock[good])

  ## 9. Neither side is at the live-contract cap.
  if sim.liveContracts(proposer) >= MaxLive:
    return failure("contract_cap", "you already have " & $MaxLive &
      " live contracts")
  if sim.liveContracts(contract.acceptor) >= MaxLive:
    return failure("contract_cap", sim.names[contract.acceptor] &
      " already has " & $MaxLive & " live contracts")

  contract.text = renderContract(sim, contract)
  ParseResult(ok: true, contract: contract)

# ---- Condition evaluation ---------------------------------------------------

proc paidUnits*(sim: Sim, contract: Contract, who: int, good: Good): int =
  ## Units of `good` that `who` has handed the OTHER party by open give
  ## since this contract was signed. Escrow movements never count: only a
  ## voluntary give does, which is what makes a PAID clause a performance
  ## bond rather than a restatement of the escrow.
  if contract.signedTurn < 0:
    return 0
  let other = if who == contract.proposer: contract.acceptor else: contract.proposer
  for transfer in sim.transfers:
    if transfer.turn >= contract.signedTurn and transfer.sender == who and
        transfer.receiver == other and transfer.good == good:
      result += transfer.n

proc evalCondition*(sim: Sim, contract: Contract): bool =
  ## Evaluated at settlement, against the floor as it stands at that
  ## moment. HOLDS reads FREE stock only — locking your own stock in an
  ## unrelated contract is how you make someone's HOLDS clause read false.
  var held =
    case contract.cond.kind
    of ckAlways:
      true
    of ckHolds:
      contract.cond.who >= 0 and contract.cond.who < Seats and
        sim.seats[contract.cond.who].stock[contract.cond.good] >=
          contract.cond.n
    of ckPaid:
      sim.paidUnits(contract, contract.cond.who, contract.cond.good) >=
        contract.cond.n
  if contract.cond.negated:
    held = not held
  held
