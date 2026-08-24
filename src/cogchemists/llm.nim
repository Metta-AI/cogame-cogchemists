## Claude-backed decision making for Cogchemists. Each seat's policy is just
## a prompt: the game server composes the seat's view (its hand, the board,
## the public record, its private experiments and its deduction grid) plus
## that seat's prompt and asks Claude what it does this phase.
##
## Decisions inside a phase are simultaneous BY RULE, so all four seats'
## requests go out as ONE parallel batch (curly.makeRequests) — 12 batches
## in a default 6-round episode, never 48 sequential calls. Invalid replies
## are retried once as a smaller batch carrying an "your previous reply was
## invalid" hint; anything still failing takes the scripted `assayer` move.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits, no spacing
## floor) so offline certification still completes — this fallback is
## load-bearing. The same scripted bots are also fieldable policies.

import
  std/[json, os, random, strutils, times, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  MaxSignatureLen* = 12

type
  ScriptKind* = enum
    skNone = "none"
    skAssayer = "assayer"
    skQuack = "quack"

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
    model: string         ## direct-Anthropic transport only
    maxOutputTokens: int
    timeoutSeconds: int
    minBatchSpacingMs*: int  ## wall-clock floor between batch STARTS
    lastBatchAt: float
    disabled*: bool   ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"assayer" play the competent
  ## scientist, "quack" the reckless careerist, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "assayer", "scientist": skAssayer
  of "quack", "careerist": skQuack
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
    echo "cogchemists llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. Haiku leads: hosted Bedrock capacity is
  ## shared account-wide and the sonnet profiles run out first.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cogchemists llm: ", client.bedrockModels[client.bedrockModel - 1],
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
    timeoutSeconds: config.llmTimeoutSeconds,
    minBatchSpacingMs: max(0, config.minBatchSpacingMs)
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
    echo "cogchemists llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl,
      ", batch spacing ", result.minBatchSpacingMs, "ms"
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cogchemists llm: anthropic transport, model ", result.model,
      ", batch spacing ", result.minBatchSpacingMs, "ms"
  else:
    result.transport = ltNone
    result.disabled = true
    ## No credentials: no network wait, no spacing floor, every seat
    ## scripted. Offline certification and the docker smoke depend on it.
    result.minBatchSpacingMs = 0
    echo "cogchemists llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc botStream(sim: Sim, seat: int): Rand =
  ## A deterministic per-decision stream, so a scripted episode replays
  ## exactly without touching the sim's own RNG.
  initRand(int64(sim.config.seed) * 1_000_003 + int64(sim.round) * 977 +
    int64(ord(sim.phase)) * 131 + int64(seat) * 17 + 5)

proc handValues(sim: Sim, seat: int): seq[int] =
  ## The distinct ingredients the seat holds, lowest index first.
  for ingredient in 0 ..< Ingredients:
    for card in sim.seats[seat].hand:
      if card == ingredient:
        result.add(ingredient)
        break

proc tryAct(sim: Sim, seat: int, act: Action): bool =
  sim.checkAct(seat, act).len == 0

proc orderedPair(x, y: int): (int, int) =
  ## Mixing is symmetric, but LEGAL MOVES spells every pair with the lower
  ## ingredient first — so a baseline must too, or its action is legal and
  ## yet not a member of the set the prompt (and test_bot) checks against.
  if x <= y: (x, y) else: (y, x)

proc assayerLab(sim: Sim, seat: int, sample: seq[Chemistry]): Action =
  let me = sim.seats[seat]
  if me.hand.len < 2:
    return newAction("forage")
  let values = handValues(sim, seat)
  var bestA = -1
  var bestB = -1
  var bestWorst = high(int)
  var discriminates: array[Ingredients, bool]
  for i in 0 ..< values.len:
    for j in i + 1 ..< values.len:
      let worst = largestBucket(sample, values[i], values[j])
      if worst < sample.len:
        discriminates[values[i]] = true
        discriminates[values[j]] = true
      if worst < bestWorst:
        bestWorst = worst
        bestA = values[i]
        bestB = values[j]
  if bestA >= 0:
    if me.coin >= StudentCost + 1:
      let act = newAction("test_student", bestA, bestB)
      if sim.tryAct(seat, act):
        return act
    if not canBeNegative(sample, bestA, bestB):
      let act = newAction("test_self", bestA, bestB)
      if sim.tryAct(seat, act):
        return act
  ## Nothing worth drinking and no coin for a student: sell off a card that
  ## tells this seat nothing.
  for ingredient in values:
    if not discriminates[ingredient]:
      let act = newAction("transmute", ingredient)
      if sim.tryAct(seat, act):
        return act
  newAction("pass")

proc assayerMarket(sim: Sim, seat: int, sample: seq[Chemistry]): Action =
  let grid = sim.grids[seat]
  ## (a) Publish only what the grid has SOLVED — never a gamble.
  for ingredient in 0 ..< Ingredients:
    if grid.solved(ingredient) and sim.sealIndex(ingredient) < 0:
      let act = newAction("publish", ingredient,
        signature = grid.solutionOf(ingredient))
      if sim.tryAct(seat, act):
        return act
  ## (b) Attack only with a reagent whose demonstration MUST expose the
  ## claim; a failed attack strengthens the fraud and costs 2 reputation.
  for index in 0 ..< sim.seals.len:
    let seal = sim.seals[index]
    if seal.status != sealStanding or seal.author == seat:
      continue
    if uint8(seal.claim) in grid.candidates[seal.ingredient]:
      continue
    for reagent in handValues(sim, seat):
      if alwaysExposes(sample, seal.ingredient, seal.claim, reagent):
        let act = newAction("debunk", seal.ingredient, reagent)
        if sim.tryAct(seat, act):
          return act
  ## (c) Sell only a pair that MUST make what the adventurer asked for.
  let demand = sim.demand[max(sim.round, 0)]
  let values = handValues(sim, seat)
  for i in 0 ..< values.len:
    for j in i + 1 ..< values.len:
      if certainPotion(sample, values[i], values[j]) == demand:
        let act = newAction("sell", values[i], values[j])
        if sim.tryAct(seat, act):
          return act
  ## (d) Bank the mortar: every later experiment then costs one card.
  if not sim.seats[seat].mortar:
    let act = newAction("buy", artifact = "mortar")
    if sim.tryAct(seat, act):
      return act
  newAction("pass")

proc quackLab(sim: Sim, seat: int): Action =
  if sim.seats[seat].hand.len < 2:
    return newAction("forage")
  var rng = botStream(sim, seat)
  let hand = sim.seats[seat].hand
  let first = rng.rand(hand.high)
  var second = rng.rand(hand.high)
  if second == first:
    second = (first + 1) mod hand.len
  let pair = orderedPair(hand[first], hand[second])
  let act = newAction("test_self", pair[0], pair[1])
  if sim.tryAct(seat, act):
    return act
  newAction("pass")

proc quackMarket(sim: Sim, seat: int): Action =
  ## Certainty be damned: the lowest candidate for the lowest unclaimed
  ## ingredient, the moment there is a coin for the wax.
  let grid = sim.grids[seat]
  for ingredient in 0 ..< Ingredients:
    if sim.sealIndex(ingredient) >= 0:
      continue
    let act = newAction("publish", ingredient,
      signature = grid.lowestCandidate(ingredient))
    if sim.tryAct(seat, act):
      return act
  let hand = sim.seats[seat].hand
  if hand.len >= 2:
    let pair = orderedPair(hand[0], hand[1])
    let act = newAction("sell", pair[0], pair[1])
    if sim.tryAct(seat, act):
      return act
  newAction("pass")

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Action =
  ## Rule-based baseline for `seat`. Always legal; never talks or notes.
  if sim.phase == phLab:
    case kind
    of skQuack: quackLab(sim, seat)
    else: assayerLab(sim, seat, consistentSample(sim.knownFacts(seat)))
  else:
    case kind
    of skQuack: quackMarket(sim, seat)
    else: assayerMarket(sim, seat, consistentSample(sim.knownFacts(seat)))

# ---- Reply parsing ----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked; a
  ## byte cut would leave invalid UTF-8 in the replay and break its JSON.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc normalizeName(text: string): string =
  for ch in text.toLowerAscii():
    if ch in {'a' .. 'z'}:
      result.add(ch)

proc resolveIngredient*(text: string): int =
  ## A full name (case-insensitive), a unique prefix of at least three
  ## letters, or the index 0-7.
  let trimmed = text.strip()
  if trimmed.len == 0:
    return -1
  var digits = true
  for ch in trimmed:
    if ch notin {'0' .. '9'}:
      digits = false
  if digits:
    let index = parseInt(trimmed)
    return (if index >= 0 and index < Ingredients: index else: -1)
  let needle = normalizeName(trimmed)
  if needle.len == 0:
    return -1
  for index in 0 ..< Ingredients:
    if normalizeName(IngredientNames[index]) == needle:
      return index
  if needle.len < 3:
    return -1
  var hit = -1
  for index in 0 ..< Ingredients:
    if normalizeName(IngredientNames[index]).startsWith(needle):
      if hit >= 0:
        return -1     ## ambiguous prefix
      hit = index
  hit

proc normalizeVerb(text: string): string =
  result = text.strip().toLowerAscii()
  result = result.replace("-", "_").replace(" ", "_")
  while "__" in result:
    result = result.replace("__", "_")

proc parseReply*(sim: Sim, seat: int, payload: JsonNode): Action =
  ## Turns one model reply into an Action. Raises CogchemistsError on
  ## anything the schema cannot read; the caller retries once and then
  ## falls back to the scripted move.
  result.a = -1
  result.b = -1
  result.signature = -1
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen)
    .replace("\n", " ").replace("\r", " ")
  let verb = normalizeVerb(cleanText(payload{"action"}.getStr(), MaxActionLen))
  if verb.len == 0:
    raise newException(CogchemistsError, "no action in response")
  let menu = if sim.phase == phLab: @LabActions else: @MarketActions
  if verb notin menu:
    raise newException(CogchemistsError,
      "\"" & verb & "\" is not a " & $sim.phase & " action")
  result.action = verb
  let aText = cleanText(payload{"a"}.getStr(), MaxActionLen)
  let bText = cleanText(payload{"b"}.getStr(), MaxActionLen)
  if verb in ["test_student", "test_self", "sell", "transmute", "publish",
      "endorse", "debunk"]:
    result.a = resolveIngredient(aText)
    if result.a < 0:
      raise newException(CogchemistsError,
        "\"" & aText & "\" is not one of the eight ingredients")
  if verb in ["test_student", "test_self", "sell", "debunk"]:
    result.b = resolveIngredient(bText)
    if result.b < 0:
      raise newException(CogchemistsError,
        "\"" & bText & "\" is not one of the eight ingredients")
  if verb == "publish":
    result.signature =
      parseSignature(cleanText(payload{"signature"}.getStr(), MaxSignatureLen))
    if result.signature < 0:
      raise newException(CogchemistsError,
        "a signature is three signs in RGB order, like R+G-B+")
  if verb == "buy":
    result.artifact =
      cleanText(payload{"artifact"}.getStr(), MaxArtifactLen).toLowerAscii()
    if result.artifact notin ["mortar", "press"]:
      raise newException(CogchemistsError,
        "the artifacts are \"mortar\" and \"press\"")

# ---- Prompt building --------------------------------------------------------

proc potionsLine(): string =
  var names: seq[string]
  for potion in ColouredPotions:
    names.add($potion)
  names.add($poMud)
  names.join(", ")

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.names[seat]
  var ingredients: seq[string]
  for name in IngredientNames:
    ingredients.add(name)
  result = "You are " & me & ", an alchemist of the Academy. Four cogs " &
    "share one laboratory for " & $sim.config.rounds & " rounds, racing to " &
    "publish a secret chemistry before anyone can disprove them.\n\n" &
    "THE EIGHT INGREDIENTS: " & ingredients.join(", ") & ".\n" &
    "A SIGNATURE is three signs over RED, GREEN and BLUE, written like " &
    "R+G-B+. There are 8. The episode's chemistry is a BIJECTION " &
    "ingredient -> signature: every signature is used exactly once, so no " &
    "two ingredients share one. Nobody is told it.\n\n" &
    """MIXING TWO INGREDIENTS:
1. Look at the aspects where the two signatures DISAGREE.
2. If they disagree on exactly ONE aspect, the potion takes that aspect's
   colour, and its sign is the product of the two aspects they AGREE on:
   "+" when those two point the same way, "-" when they point opposite ways.
3. If they disagree on two or three aspects (or on none, i.e. the same
   ingredient twice), the potion is MUD.
The only possible potions are: """ & potionsLine() & """.
Each coloured potion is made by exactly 2 of the 28 signature pairs and MUD
by the other 16, so a coloured result is a very strong clue and MUD a weak
one.

EACH ROUND HAS TWO PHASES. In LAB you take exactly one of:
- forage: draw 2 ingredient cards (hand cap 6). The cards drawn are PUBLIC.
- test_student a b: -1 coin. Consumes both cards (only a with the Magic
  Mortar). You learn the potion; rivals see only which two cards you burned.
- test_self a b: free. Consumes both cards (only a with the Mortar). You
  learn the potion AND drink it: a negative potion poisons you (-2
  reputation), a positive one is a triumph (+1). Everyone sees the SIGN
  CLASS (positive / negative / mud); the colour stays yours.
- transmute a: consume one card for +2 coin.
- pass: +1 coin.

In MARKET you take exactly one of:
- sell a b: consume both cards and sell the potion to this round's
  adventurer. Hit (it is exactly what they asked for): +6 coin, +1
  reputation. Miss (anything else, MUD included): +2 coin, -1 reputation.
  The potion is PUBLIC either way, so selling is also how you leak.
- publish a SIG: -1 coin. Pin a wax seal claiming that ingredient has that
  signature. Immediate +2 reputation (+3 with the Printing Press) — credit
  is paid for the claim, not for being right. Legal only where no seal
  stands. Standing seals earn their author +1 coin every round open.
- endorse a: -1 coin, paid to the author. Co-sign a rival's standing seal.
  At the exhibition you take +2 if it was true, -3 if it was false; -1 if
  it burns first.
- debunk a b: -1 coin and consumes card b. A public demonstration against
  the standing seal on a: the academy supplies a, you supply b, and the
  REAL potion is revealed to everyone. If it differs from what the claim
  predicts the seal BURNS (author -4, you +3, each endorser -1) and a
  becomes publishable again. If it matches, your attack FAILS: you -2, the
  author +1, and the seal stands stronger. Attacking needs a reagent that
  must expose the lie.
- buy mortar (-4 coin) or buy press (-5 coin), once each.
- pass: +1 coin.

THE EXHIBITION, after the last round: every still-standing seal is opened
against the truth. True: author +5 reputation, each endorser +2. False:
author -6, each endorser -3. Seals already burned are not re-scored.

SCORE = reputation + 0.2 x coin. HIGHER IS BETTER and it may go negative.
Everyone starts on reputation 10 and coin 4.

Decisions inside a phase are SIMULTANEOUS. A move that is legal now can
still be rejected by an earlier seat in the same phase (two seats
publishing the same ingredient, a debunk of a seal that has just burned);
a rejected move is recorded as such and degrades to pass (+1 coin).

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc gridBlock*(sim: Sim, seat: int): string =
  let grid = sim.grids[seat]
  var lines: seq[string]
  lines.add("YOUR DEDUCTION GRID (" & $grid.chemistries &
    " chemistries still possible)")
  for ingredient in 0 ..< Ingredients:
    var names: seq[string]
    for sig in grid.candidateList(ingredient):
      names.add(sigName(sig))
    let count =
      if grid.solved(ingredient): "SOLVED"
      else: $names.len
    lines.add(IngredientNames[ingredient].alignLeft(14) & count.alignLeft(8) &
      names.join(" | "))
  lines.join("\n")

proc publicLine*(sim: Sim, event: GameEvent): string =
  ## One line of the public record: what a rival could actually see. The
  ## private half of a test never appears here.
  if event.kind != evAct:
    return ""
  let who = sim.names[event.seat]
  let a = if event.a >= 0: IngredientNames[event.a] else: ""
  let b = if event.b >= 0: IngredientNames[event.b] else: ""
  if event.outcome.startsWith("rejected:"):
    return who & " tried to " & event.action & " but was rejected (" &
      event.outcome["rejected:".len .. ^1] & ") and passed"
  case event.action
  of "forage":
    var drawn: seq[string]
    for card in event.draws:
      drawn.add(IngredientNames[card])
    return who & " foraged and drew " & drawn.join(" + ")
  of "test_student":
    return who & " tested " & a & " + " & b &
      " on a student; the result is private to " & who
  of "test_self":
    return who & " drank " & a & " + " & b & " — " &
      $signClassOf(event.potion) & " (colour private to " & who & ")"
  of "transmute":
    return who & " transmuted " & a & " for coin"
  of "sell":
    return who & " sold " & a & " + " & b & ": " & $event.potion & " — " &
      (if event.outcome == "hit": "the adventurer wanted exactly that"
       else: "not what the adventurer wanted")
  of "publish":
    return who & " published: " & a & " is " & sigName(event.signature)
  of "endorse":
    return who & " endorsed " & sim.names[event.target] & "'s " & a & " seal"
  of "debunk":
    return who & " demonstrated " & a & " with " & b & " -> " &
      $event.potion & "; the seal " &
      (if event.outcome == "burned": "BURNED" else: "stood")
  else:
    return who & " passed"

proc recordBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  var round = -1
  var phase = phLab
  for event in sim.events:
    if event.kind != evAct:
      continue
    if event.round != round or event.phase != phase:
      round = event.round
      phase = event.phase
      lines.add("Round " & $(round + 1) & " " &
        ($phase).toUpperAscii() & ":")
    lines.add("  " & sim.publicLine(event))
  result = "PUBLIC RECORD (everything every seat could see):\n" &
    (if lines.len > 0: lines.join("\n") else: "(nothing yet)") & "\n\n"

proc factsBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  for fact in sim.seats[seat].privateFacts:
    lines.add("  " & IngredientNames[fact.a] & " + " &
      IngredientNames[fact.b] & " = " & $fact.potion)
  result = "YOUR PRIVATE EXPERIMENTS (only you know these results):\n" &
    (if lines.len > 0: lines.join("\n") else: "  (none)") & "\n\n"

proc boardBlock(sim: Sim): string =
  var lines: seq[string]
  for seal in sim.seals:
    var endorsers: seq[string]
    for endorser in seal.endorsers:
      endorsers.add(sim.names[endorser])
    lines.add("  " & IngredientNames[seal.ingredient] & " = " &
      sigName(seal.claim) & " — claimed by " & sim.names[seal.author] &
      " in round " & $(seal.roundPublished + 1) & ", " & $seal.status &
      (if seal.status == sealBurned: " (burned by " &
        sim.names[seal.burnedBy] & ")" else: "") &
      (if seal.vindications > 0: ", survived " & $seal.vindications &
        " challenge(s)" else: "") &
      (if endorsers.len > 0: ", endorsed by " & endorsers.join(", ")
       else: ""))
  result = "THE BOARD (wax seals):\n" &
    (if lines.len > 0: lines.join("\n") else: "  (no theory published yet)") &
    "\n\n"

proc tableBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  for other in 0 ..< Seats:
    var badges: seq[string]
    if sim.seats[other].mortar: badges.add("mortar")
    if sim.seats[other].press: badges.add("press")
    lines.add("  " & sim.names[other] & (if other == seat: " (you)" else: "") &
      ": reputation " & $sim.seats[other].reputation &
      ", coin " & $sim.seats[other].coin &
      ", score " & formatFloat(sim.score(other), ffDecimal, 1) &
      ", " & $sim.seats[other].hand.len & " cards in hand" &
      (if badges.len > 0: ", owns " & badges.join(" + ") else: ""))
  var order: seq[string]
  for other in initiativeOrder(max(sim.round, 0)):
    order.add(sim.names[other])
  result = "TABLE:\n" & lines.join("\n") & "\nInitiative this round: " &
    order.join(" -> ") & "\n\n"

proc heardBlock(sim: Sim): string =
  if not sim.config.talk:
    return ""
  var lines: seq[string]
  for other in 0 ..< Seats:
    if sim.seats[other].heard.len > 0:
      lines.add("  " & sim.names[other] & ": \"" & sim.seats[other].heard &
        "\"")
  "REMARKS LAST PHASE:\n" &
    (if lines.len > 0: lines.join("\n") else: "  (nobody spoke)") & "\n\n"

proc handBlock(sim: Sim, seat: int): string =
  var cards: seq[string]
  for ingredient in 0 ..< Ingredients:
    for card in sim.seats[seat].hand:
      if card == ingredient:
        cards.add(IngredientNames[ingredient])
  if cards.len == 0: "(empty)" else: cards.join(", ")

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let me = sim.seats[seat]
  result.add("Round " & $(sim.round + 1) & " of " & $sim.config.rounds &
    ", " & ($sim.phase).toUpperAscii() & " phase. The adventurer this " &
    "round wants " & $sim.demand[max(sim.round, 0)] & ".\n\n")
  result.add("YOU are " & sim.names[seat] & ": reputation " &
    $me.reputation & ", coin " & $me.coin & ", score " &
    formatFloat(sim.score(seat), ffDecimal, 1) & ".\n")
  result.add("YOUR HAND: " & sim.handBlock(seat) & "\n")
  result.add("YOUR ARTIFACTS: " &
    (if me.mortar and me.press: "Magic Mortar, Printing Press"
     elif me.mortar: "Magic Mortar"
     elif me.press: "Printing Press"
     else: "(none)") & "\n\n")
  result.add(sim.tableBlock(seat))
  result.add(sim.boardBlock())
  result.add(sim.recordBlock(seat))
  result.add(sim.factsBlock(seat))
  result.add(sim.gridBlock(seat) & "\n\n")
  result.add(sim.heardBlock())
  result.add("YOUR NOTES FROM EARLIER PHASES:\n" &
    (if me.notes.len > 0: me.notes else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  var moves: seq[string]
  for move in sim.legalMoves(seat):
    moves.add("  " & move)
  result.add("LEGAL MOVES (exactly these; anything else is rejected):\n" &
    moves.join("\n") & "\n\n")
  result.add("Reply with ONLY a JSON object like " &
    "{\"action\":\"publish\",\"a\":\"Nightcap\",\"b\":\"\"," &
    "\"signature\":\"R+G-B+\",\"artifact\":\"\"" &
    (if sim.config.talk: ",\"say\":\"…\"" else: "") &
    ",\"notes\":\"…\"} — copy one of the LEGAL MOVES above into the " &
    "action/a/b/signature/artifact fields" &
    (if sim.config.talk: "; say is a public remark of at most " &
      $MaxSayLen & " characters (or \"\")" else: "") &
    "; notes is your private notebook, at most " & $MaxNotesLen &
    " characters, and comes back to you next phase.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating
  ## fences and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(CogchemistsError, "no JSON object in response: " &
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
  ## The text of one batched reply, or a CogchemistsError describing why
  ## there is none. Auth failures disable the client; model-access and
  ## throttle failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(CogchemistsError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CogchemistsError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(CogchemistsError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(CogchemistsError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(CogchemistsError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CogchemistsError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(CogchemistsError, "reply cut off at max_tokens " &
      "before any JSON: " & result[0 .. min(result.high, 160)]
        .replace("\n", " "))

proc awaitBatchSlot(client: LlmClient) =
  ## The hosted Bedrock sidecar caps 30 requests per minute per episode and
  ## four seats per batch with no wall-clock floor can exceed it. Skipped
  ## entirely when the client is disabled (no network happens at all).
  if client.disabled or client.minBatchSpacingMs <= 0:
    return
  let now = epochTime()
  let earliest = client.lastBatchAt + client.minBatchSpacingMs.float / 1000.0
  if client.lastBatchAt > 0.0 and now < earliest:
    sleep(int((earliest - now) * 1000.0))

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  fromScript: var seq[bool]
): seq[Action] =
  ## One decision per seat in `seats`, in order, as ONE parallel batch.
  ## Never raises: any failure falls back to the scripted baseline so the
  ## episode always advances. `prompts` and `scripted` are indexed by SEAT.
  ##
  ## `fromScript` is indexed like the result (by POSITION in `seats`) and is
  ## true wherever the returned action came from the baseline rather than a
  ## model reply: a configured scripted seat, a disabled client, AND a seat
  ## that fell back after its retry. The caller records exactly this flag,
  ## so a fallback is never recorded as a real decision.
  result = newSeq[Action](seats.len)
  fromScript = newSeq[bool](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skAssayer else: kind))
      fromScript[index] = true
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was invalid. Respond with ONLY " &
          "the requested JSON object, copying one line of LEGAL MOVES.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    client.awaitBatchSlot()
    client.lastBatchAt = epochTime()
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let action = parseReply(sim, seat, extractJsonObject(text))
        ## Reject moves the rules refuse HERE, so the retry carries the
        ## hint instead of the episode taking a silent fallback.
        var probe = sim
        probe.applyAct(seat, action, false)
        result[index] = action
      except CatchableError as error:
        echo "cogchemists llm: seat ", seat, " attempt ", attempt,
          " failed: ", error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "cogchemists llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skAssayer)
    fromScript[index] = true
