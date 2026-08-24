## Pure game rules for Cogchemists. No IO, no networking, no LLM — the
## server, the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded chemistry and adventurer
## demands, the four seats, the theory board, the public record of facts,
## every seat's deduction grid, and the append-only event log. Everything
## random is drawn from the seed, so a replay re-derives the episode from
## the recorded events alone and `replayMatch` checks the re-derivation
## against what was recorded.

import std/[algorithm, json, random, strutils, unicode], types

export types

const
  Seats* = 4
  MinRounds* = 3
  MaxRounds* = 10
  StartCoin* = 4
  StartReputation* = 10
  StartHand* = 3
  HandCap* = 6
  ForageDraw* = 2
  StudentCost* = 1
  TransmuteCoin* = 2
  PassCoin* = 1
  SellHitCoin* = 6
  SellMissCoin* = 2
  PublishCost* = 1
  PublishRep* = 2
  PressPublishRep* = 3
  RoyaltyCoin* = 1
  PressRoyaltyCoin* = 2
  EndorseCost* = 1
  DebunkCost* = 1
  BurnAuthorRep* = -4
  BurnDebunkerRep* = 3
  BurnEndorserRep* = -1
  SurviveDebunkerRep* = -2
  SurviveAuthorRep* = 1
  DrinkPositiveRep* = 1
  DrinkNegativeRep* = -2
  SellHitRep* = 1
  SellMissRep* = -1
  ExhibitTrueAuthor* = 5
  ExhibitTrueEndorser* = 2
  ExhibitFalseAuthor* = -6
  ExhibitFalseEndorser* = -3
  MortarCost* = 4
  PressCost* = 5
  CoinWeight* = 0.2
  MaxSayLen* = 140
  MaxNotesLen* = 600
  MaxActionLen* = 24
  MaxArtifactLen* = 12
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  LabActions* = ["forage", "test_student", "test_self", "transmute", "pass"]
  MarketActions* = ["sell", "publish", "endorse", "debunk", "buy", "pass"]

type
  Step* = enum
    ## What the episode owes next. Exactly one event comes out of each
    ## `advance`, so every recorded event has its own distinct frame.
    stRoundOpen = "round-open"
    stPhaseOpen = "phase-open"
    stActing = "acting"
    stExhibition = "exhibition"
    stSettle = "settle"
    stDone = "done"

  Action* = object
    action*: string
    a*, b*: int
    signature*: int
    artifact*: string
    say*: string
    notes*: string

  Bench* = object
    ## The mix currently on the lab table — what the flask animates.
    active*: bool
    seat*, a*, b*: int
    potion*: Potion
    secret*: bool

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous table aliases per seat
    chemistry*: Chemistry          ## the truth; never in a player frame
    demand*: seq[Potion]           ## one coloured potion per round
    round*: int
    phase*: Phase
    step*: Step
    seats*: array[Seats, SeatState]
    seals*: seq[Seal]
    publicFacts*: seq[Fact]
    grids*: array[Seats, Grid]
    gridVersion*: array[Seats, int]
    factsVersion*: array[Seats, int]
    acted*: array[Seats, bool]
    lastAction*: array[Seats, string]
    lastResult*: array[Seats, string]
    publishedCount*: array[Seats, int]
    trueTheories*: array[Seats, int]
    falseTheories*: array[Seats, int]
    burnedCount*: array[Seats, int]
    debunkCount*: array[Seats, int]
    bench*: Bench
    roundsPlayed*: int
    exhibited*: bool
    rng*: Rand
    done*: bool
    reason*: string                ## "complete" | "deadline"
    events*: seq[GameEvent]

proc newAction*(action: string, a = -1, b = -1, signature = -1,
    artifact = "", say = "", notes = ""): Action =
  Action(action: action, a: a, b: b, signature: signature,
    artifact: artifact, say: say, notes: notes)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the round count and the pacing delay into the episode's limits.
  ## Idempotent: a config that already carries the cap (a replay being
  ## re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.rounds = max(min(config.rounds, MaxRounds), MinRounds)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(2 * result.rounds, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, seat: -1, a: -1, b: -1, signature: -1,
    target: -1, potion: poNone, demand: poNone)

proc drawCard(sim: var Sim): int =
  sim.rng.rand(Ingredients - 1)

proc knownFacts*(sim: Sim, seat: int): seq[Fact] =
  ## Everything seat `seat` may reason from: the public record plus its own
  ## private experiments.
  result = sim.publicFacts
  for fact in sim.seats[seat].privateFacts:
    result.add(fact)

proc refreshGrids*(sim: var Sim) =
  ## Recomputes each seat's deduction grid from the facts it holds right
  ## now. Memoised: a seat whose facts have not moved keeps its grid.
  for seat in 0 ..< Seats:
    if sim.gridVersion[seat] != sim.factsVersion[seat] or
        sim.grids[seat].chemistries == 0:
      sim.grids[seat] = solveGrid(sim.knownFacts(seat))
      sim.gridVersion[seat] = sim.factsVersion[seat]

proc addPublicFact(sim: var Sim, fact: Fact) =
  sim.publicFacts.add(fact)
  for seat in 0 ..< Seats:
    inc sim.factsVersion[seat]

proc addPrivateFact(sim: var Sim, seat: int, fact: Fact) =
  sim.seats[seat].privateFacts.add(fact)
  inc sim.factsVersion[seat]

proc initiativeOrder*(round: int): seq[int] =
  ## order[i] = (i + round) mod Seats, so the lead rotates and no seat is
  ## structurally first.
  for index in 0 ..< Seats:
    result.add((index + round) mod Seats)

proc seatSnapshot(sim: Sim, seat: int): SeatSnapshot

proc openRound(sim: var Sim, round: int) =
  ## Round open: pay royalties on every standing seal, publish the
  ## adventurer's demand and the initiative order.
  sim.round = round
  var royalties = newSeq[int](Seats)
  for seal in sim.seals:
    if seal.status == sealStanding:
      let amount =
        if sim.seats[seal.author].press: PressRoyaltyCoin else: RoyaltyCoin
      sim.seats[seal.author].coin += amount
      royalties[seal.author] += amount
  ## Nobody is due to act until a phase opens.
  for seat in 0 ..< Seats:
    sim.acted[seat] = true
  var event = blankEvent(evRound)
  event.round = round
  event.phase = sim.phase
  event.demand = sim.demand[round]
  event.initiative = initiativeOrder(round)
  event.royalties = royalties
  for seat in 0 ..< Seats:
    event.seats.add(sim.seatSnapshot(seat))
  sim.addEvent(event)

proc openPhase(sim: var Sim, phase: Phase) =
  sim.phase = phase
  for seat in 0 ..< Seats:
    sim.acted[seat] = false
    sim.seats[seat].heard = sim.seats[seat].say
    sim.seats[seat].say = ""
  sim.bench = Bench(active: false, seat: -1, a: -1, b: -1, potion: poNone)
  sim.refreshGrids()
  var event = blankEvent(evPhase)
  event.round = sim.round
  event.phase = phase
  sim.addEvent(event)

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(CogchemistsError,
      "cogchemists needs exactly " & $Seats & " players")
  if config.rounds < MinRounds:
    raise newException(CogchemistsError,
      "rounds must be at least " & $MinRounds)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  result.round = -1
  result.phase = phLab
  result.step = stRoundOpen
  result.bench = Bench(active: false, seat: -1, a: -1, b: -1, potion: poNone)
  ## One stream for everything the seed decides: the chemistry, then the
  ## demands, then the opening hands, then every forage.
  result.rng = initRand(int64(config.seed) * 7919 + 17)
  result.chemistry = drawChemistry(result.rng)
  for round in 0 ..< config.rounds:
    result.demand.add(ColouredPotions[result.rng.rand(ColouredPotions.high)])
  var hands: seq[seq[int]]
  for seat in 0 ..< Seats:
    result.seats[seat].coin = StartCoin
    result.seats[seat].reputation = StartReputation
    var hand: seq[int]
    for _ in 0 ..< StartHand:
      hand.add(result.drawCard())
    result.seats[seat].hand = hand
    hands.add(hand)
    result.acted[seat] = true
    result.factsVersion[seat] = 1
  result.refreshGrids()
  var event = blankEvent(evStart)
  for index in 0 ..< Ingredients:
    event.chemistry.add(result.chemistry[index])
  event.hands = hands
  result.addEvent(event)

# ---- Queries ----------------------------------------------------------------

proc score*(sim: Sim, seat: int): float =
  ## Reputation is the point; coin is the tiebreaker at a fifth of a
  ## reputation point each. Higher is better, and it may be negative.
  sim.seats[seat].reputation.float + CoinWeight * sim.seats[seat].coin.float

proc seatSnapshot(sim: Sim, seat: int): SeatSnapshot =
  SeatSnapshot(
    coin: sim.seats[seat].coin,
    reputation: sim.seats[seat].reputation,
    handCount: sim.seats[seat].hand.len,
    mortar: sim.seats[seat].mortar,
    press: sim.seats[seat].press,
    score: sim.score(seat)
  )

proc pendingSeats*(sim: Sim): seq[int] =
  ## Seats whose action this phase is still due, in seat order. Empty once
  ## the episode is over or between phases.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if not sim.acted[seat]:
      result.add(seat)

proc allActed*(sim: Sim): bool =
  for seat in 0 ..< Seats:
    if not sim.acted[seat]:
      return false
  true

proc sealIndex*(sim: Sim, ingredient: int): int =
  ## The index of the STANDING seal on `ingredient`, or -1.
  result = -1
  for index, seal in sim.seals:
    if seal.ingredient == ingredient and seal.status == sealStanding:
      return index

proc handCount(hand: seq[int], ingredient: int): int =
  for card in hand:
    if card == ingredient:
      inc result

proc holds(sim: Sim, seat: int, cards: seq[int]): bool =
  ## Multiset containment: two of the same ingredient needs two cards.
  for ingredient in 0 ..< Ingredients:
    var needed = 0
    for card in cards:
      if card == ingredient:
        inc needed
    if needed > handCount(sim.seats[seat].hand, ingredient):
      return false
  true

proc takeCard(sim: var Sim, seat, ingredient: int) =
  for index, card in sim.seats[seat].hand:
    if card == ingredient:
      sim.seats[seat].hand.delete(index)
      return

proc mortarSpare(sim: Sim, seat: int): bool =
  ## With the Magic Mortar a test consumes only the first card.
  sim.seats[seat].mortar

proc ingredientOk(index: int): bool =
  index >= 0 and index < Ingredients

# ---- Legality ---------------------------------------------------------------

proc checkAct*(sim: Sim, seat: int, act: Action): string =
  ## "" when the action is legal for this seat right now, otherwise the
  ## reason token. `legalMoves` filters candidates through this exact
  ## predicate, so the LEGAL MOVES block in a prompt and the validator can
  ## never disagree.
  if sim.done:
    return "episode_over"
  if seat < 0 or seat >= Seats:
    return "bad_seat"
  if sim.acted[seat]:
    return "already_acted"
  if sim.step != stActing:
    return "phase_not_open"
  let me = sim.seats[seat]
  case act.action
  of "pass":
    return ""
  of "forage":
    if sim.phase != phLab: return "wrong_phase"
    return ""
  of "test_student", "test_self":
    if sim.phase != phLab: return "wrong_phase"
    if not ingredientOk(act.a) or not ingredientOk(act.b):
      return "unknown_ingredient"
    if not sim.holds(seat, @[act.a, act.b]): return "missing_card"
    if act.action == "test_student" and me.coin < StudentCost:
      return "no_coin"
    return ""
  of "transmute":
    if sim.phase != phLab: return "wrong_phase"
    if not ingredientOk(act.a): return "unknown_ingredient"
    if not sim.holds(seat, @[act.a]): return "missing_card"
    return ""
  of "sell":
    if sim.phase != phMarket: return "wrong_phase"
    if not ingredientOk(act.a) or not ingredientOk(act.b):
      return "unknown_ingredient"
    if not sim.holds(seat, @[act.a, act.b]): return "missing_card"
    return ""
  of "publish":
    if sim.phase != phMarket: return "wrong_phase"
    if not ingredientOk(act.a): return "unknown_ingredient"
    if act.signature < 0 or act.signature >= Signatures:
      return "bad_signature"
    if me.coin < PublishCost: return "no_coin"
    if sim.sealIndex(act.a) >= 0: return "already_claimed"
    return ""
  of "endorse":
    if sim.phase != phMarket: return "wrong_phase"
    if not ingredientOk(act.a): return "unknown_ingredient"
    let index = sim.sealIndex(act.a)
    if index < 0: return "no_such_theory"
    if sim.seals[index].author == seat: return "own_theory"
    if seat in sim.seals[index].endorsers: return "already_endorsed"
    if me.coin < EndorseCost: return "no_coin"
    return ""
  of "debunk":
    if sim.phase != phMarket: return "wrong_phase"
    if not ingredientOk(act.a) or not ingredientOk(act.b):
      return "unknown_ingredient"
    let index = sim.sealIndex(act.a)
    if index < 0: return "no_such_theory"
    if sim.seals[index].author == seat: return "own_theory"
    if not sim.holds(seat, @[act.b]): return "missing_card"
    if me.coin < DebunkCost: return "no_coin"
    return ""
  of "buy":
    if sim.phase != phMarket: return "wrong_phase"
    if not sim.config.artifacts: return "artifacts_disabled"
    case act.artifact
    of "mortar":
      if me.mortar: return "already_owned"
      if me.coin < MortarCost: return "no_coin"
      return ""
    of "press":
      if me.press: return "already_owned"
      if me.coin < PressCost: return "no_coin"
      return ""
    else:
      return "unknown_artifact"
  else:
    return "unknown_action"

proc showAct*(act: Action): string =
  ## The exact spelling a seat may put in LEGAL MOVES, with every field of
  ## the reply schema named so the mapping to JSON is unambiguous even for
  ## ingredients whose names contain spaces.
  result = act.action
  if ingredientOk(act.a):
    result.add(" a=\"" & IngredientNames[act.a] & "\"")
  if ingredientOk(act.b):
    result.add(" b=\"" & IngredientNames[act.b] & "\"")
  if act.signature >= 0:
    result.add(" signature=\"" & sigName(act.signature) & "\"")
  if act.artifact.len > 0:
    result.add(" artifact=\"" & act.artifact & "\"")

proc candidateActs(sim: Sim, seat: int): seq[Action] =
  ## Every action shape the seat could conceivably name this phase; the
  ## legality filter is applied by `legalMoves`.
  var cards: seq[int]
  for ingredient in 0 ..< Ingredients:
    if handCount(sim.seats[seat].hand, ingredient) > 0:
      cards.add(ingredient)
  if sim.phase == phLab:
    result.add(newAction("forage"))
    for i in 0 ..< cards.len:
      for j in i ..< cards.len:
        result.add(newAction("test_student", cards[i], cards[j]))
    for i in 0 ..< cards.len:
      for j in i ..< cards.len:
        result.add(newAction("test_self", cards[i], cards[j]))
    for card in cards:
      result.add(newAction("transmute", card))
  else:
    for i in 0 ..< cards.len:
      for j in i ..< cards.len:
        result.add(newAction("sell", cards[i], cards[j]))
    for ingredient in 0 ..< Ingredients:
      for sig in 0 ..< Signatures:
        result.add(newAction("publish", ingredient, signature = sig))
    for ingredient in 0 ..< Ingredients:
      result.add(newAction("endorse", ingredient))
      for card in cards:
        result.add(newAction("debunk", ingredient, card))
    result.add(newAction("buy", artifact = "mortar"))
    result.add(newAction("buy", artifact = "press"))
  result.add(newAction("pass"))

proc legalActs*(sim: Sim, seat: int): seq[Action] =
  for act in candidateActs(sim, seat):
    if sim.checkAct(seat, act).len == 0:
      result.add(act)

proc legalMoves*(sim: Sim, seat: int): seq[string] =
  for act in legalActs(sim, seat):
    result.add(showAct(act))

# ---- Play -------------------------------------------------------------------

proc cleanSay(sim: Sim, say: string): string =
  if not sim.config.talk:
    return ""
  result = say.strip().replace("\n", " ").replace("\r", " ")
  ## Cut on a RUNE boundary: a byte slice through a multi-byte character
  ## leaves invalid UTF-8 in the replay and breaks its JSON.
  if result.runeLen > MaxSayLen:
    result = result.runeSubStr(0, MaxSayLen)

proc cleanNotes(notes: string): string =
  result = notes.strip()
  if result.runeLen > MaxNotesLen:
    result = result.runeSubStr(0, MaxNotesLen)

proc recordTalk(sim: var Sim, seat: int, act: Action, event: var GameEvent) =
  let say = sim.cleanSay(act.say)
  sim.seats[seat].say = say
  if act.notes.len > 0:
    sim.seats[seat].notes = cleanNotes(act.notes)
  event.say = say
  event.text = sim.seats[seat].notes

proc finishAct(sim: var Sim, seat: int, event: var GameEvent) =
  sim.acted[seat] = true
  sim.lastAction[seat] = event.action
  sim.lastResult[seat] = event.outcome
  sim.addEvent(event)
  if sim.allActed() and sim.phase == phMarket:
    inc sim.roundsPlayed

proc applyAct*(sim: var Sim, seat: int, act: Action, scripted: bool) =
  ## Applies one seat's action. Raises CogchemistsError on anything
  ## illegal; the server records the rejection and degrades to `pass`.
  let reason = sim.checkAct(seat, act)
  if reason.len > 0:
    raise newException(CogchemistsError, reason)
  var event = blankEvent(evAct)
  event.round = sim.round
  event.phase = sim.phase
  event.seat = seat
  event.action = act.action
  event.a = act.a
  event.b = act.b
  event.signature = act.signature
  event.artifact = act.artifact
  event.scripted = scripted
  event.outcome = "ok"
  sim.recordTalk(seat, act, event)
  sim.bench = Bench(active: false, seat: -1, a: -1, b: -1, potion: poNone)

  case act.action
  of "forage":
    for _ in 0 ..< ForageDraw:
      let card = sim.drawCard()
      event.draws.add(card)
      if sim.seats[seat].hand.len < HandCap:
        sim.seats[seat].hand.add(card)
      else:
        event.discarded.add(card)
  of "test_student", "test_self":
    let potion = sim.chemistry.mix(act.a, act.b)
    sim.takeCard(seat, act.a)
    if not sim.mortarSpare(seat):
      sim.takeCard(seat, act.b)
    event.potion = potion
    event.secret = true
    sim.addPrivateFact(seat, mixFullFact(act.a, act.b, potion))
    if act.action == "test_student":
      sim.seats[seat].coin -= StudentCost
      event.coinDelta = -StudentCost
    else:
      ## Everyone sees you glow or retch: the sign class is public, the
      ## colour is not.
      sim.addPublicFact(mixSignFact(act.a, act.b, signClassOf(potion)))
      case signClassOf(potion)
      of scPositive:
        sim.seats[seat].reputation += DrinkPositiveRep
        event.repDelta = DrinkPositiveRep
        event.outcome = "glowed"
      of scNegative:
        sim.seats[seat].reputation += DrinkNegativeRep
        event.repDelta = DrinkNegativeRep
        event.outcome = "poisoned"
      of scMud:
        event.outcome = "ok"
    sim.bench = Bench(active: true, seat: seat, a: act.a, b: act.b,
      potion: potion, secret: true)
  of "transmute":
    sim.takeCard(seat, act.a)
    sim.seats[seat].coin += TransmuteCoin
    event.coinDelta = TransmuteCoin
  of "sell":
    let potion = sim.chemistry.mix(act.a, act.b)
    sim.takeCard(seat, act.a)
    sim.takeCard(seat, act.b)
    event.potion = potion
    event.secret = false
    sim.addPublicFact(mixFullFact(act.a, act.b, potion))
    if potion == sim.demand[sim.round]:
      sim.seats[seat].coin += SellHitCoin
      sim.seats[seat].reputation += SellHitRep
      event.coinDelta = SellHitCoin
      event.repDelta = SellHitRep
      event.outcome = "hit"
    else:
      sim.seats[seat].coin += SellMissCoin
      sim.seats[seat].reputation += SellMissRep
      event.coinDelta = SellMissCoin
      event.repDelta = SellMissRep
      event.outcome = "miss"
    sim.bench = Bench(active: true, seat: seat, a: act.a, b: act.b,
      potion: potion, secret: false)
  of "publish":
    sim.seats[seat].coin -= PublishCost
    let gain = if sim.seats[seat].press: PressPublishRep else: PublishRep
    sim.seats[seat].reputation += gain
    event.coinDelta = -PublishCost
    event.repDelta = gain
    sim.seals.add(Seal(ingredient: act.a, claim: act.signature, author: seat,
      roundPublished: sim.round, status: sealStanding, burnedBy: -1,
      roundBurned: -1))
    sim.seats[seat].published.add(act.a)
    inc sim.publishedCount[seat]
  of "endorse":
    let index = sim.sealIndex(act.a)
    let author = sim.seals[index].author
    sim.seats[seat].coin -= EndorseCost
    sim.seats[author].coin += EndorseCost
    sim.seals[index].endorsers.add(seat)
    sim.seats[seat].endorsed.add(act.a)
    event.coinDelta = -EndorseCost
    event.target = author
  of "debunk":
    let index = sim.sealIndex(act.a)
    let author = sim.seals[index].author
    let claim = sim.seals[index].claim
    sim.seats[seat].coin -= DebunkCost
    sim.takeCard(seat, act.b)
    event.coinDelta = -DebunkCost
    event.target = author
    ## The academy supplies a sample of x; the attacker supplies y. The
    ## real potion is public either way.
    let real = sim.chemistry.mix(act.a, act.b)
    let predicted = mixSignatures(claim, sim.chemistry[act.b])
    event.potion = real
    event.secret = false
    sim.addPublicFact(mixFullFact(act.a, act.b, real))
    if real != predicted:
      sim.seals[index].status = sealBurned
      sim.seals[index].burnedBy = seat
      sim.seals[index].roundBurned = sim.round
      sim.seats[author].reputation += BurnAuthorRep
      sim.seats[seat].reputation += BurnDebunkerRep
      for endorser in sim.seals[index].endorsers:
        sim.seats[endorser].reputation += BurnEndorserRep
      sim.addPublicFact(notSigFact(act.a, claim))
      inc sim.burnedCount[author]
      inc sim.debunkCount[seat]
      event.repDelta = BurnDebunkerRep
      event.outcome = "burned"
    else:
      sim.seats[seat].reputation += SurviveDebunkerRep
      sim.seats[author].reputation += SurviveAuthorRep
      inc sim.seals[index].vindications
      event.repDelta = SurviveDebunkerRep
      event.outcome = "survived"
    sim.bench = Bench(active: true, seat: seat, a: act.a, b: act.b,
      potion: real, secret: false)
  of "buy":
    if act.artifact == "mortar":
      sim.seats[seat].mortar = true
      sim.seats[seat].coin -= MortarCost
      event.coinDelta = -MortarCost
    else:
      sim.seats[seat].press = true
      sim.seats[seat].coin -= PressCost
      event.coinDelta = -PressCost
  else:
    ## pass
    sim.seats[seat].coin += PassCoin
    event.coinDelta = PassCoin
  sim.finishAct(seat, event)

proc applyRejection*(sim: var Sim, seat: int, act: Action, reason: string,
    scripted: bool) =
  ## An action that was legal when the phase opened but was undone by an
  ## earlier seat in the same phase. Recorded with its reason and degraded
  ## to `pass`, so the episode always advances.
  var event = blankEvent(evAct)
  event.round = sim.round
  event.phase = sim.phase
  event.seat = seat
  event.action = act.action
  event.a = act.a
  event.b = act.b
  event.signature = act.signature
  event.artifact = act.artifact
  event.scripted = scripted
  event.outcome = "rejected:" & reason
  sim.recordTalk(seat, act, event)
  sim.seats[seat].coin += PassCoin
  event.coinDelta = PassCoin
  sim.bench = Bench(active: false, seat: -1, a: -1, b: -1, potion: poNone)
  sim.finishAct(seat, event)

proc runExhibition(sim: var Sim) =
  ## Every STANDING seal is opened against the truth. Seals already burned
  ## settled at the burn and are not re-scored.
  var event = blankEvent(evExhibition)
  event.round = max(sim.round, 0)
  var deltas = newSeq[int](Seats)
  for index in 0 ..< sim.seals.len:
    let seal = sim.seals[index]
    if seal.status != sealStanding:
      continue
    let correct = sim.chemistry[seal.ingredient] == seal.claim
    if correct:
      deltas[seal.author] += ExhibitTrueAuthor
      for endorser in seal.endorsers:
        deltas[endorser] += ExhibitTrueEndorser
      inc sim.trueTheories[seal.author]
    else:
      deltas[seal.author] += ExhibitFalseAuthor
      for endorser in seal.endorsers:
        deltas[endorser] += ExhibitFalseEndorser
      inc sim.falseTheories[seal.author]
    event.verdicts.add(Verdict(ingredient: seal.ingredient, claim: seal.claim,
      author: seal.author, endorsers: seal.endorsers, correct: correct))
  for seat in 0 ..< Seats:
    sim.seats[seat].reputation += deltas[seat]
  event.repDeltas = deltas
  for index in 0 ..< Ingredients:
    event.chemistry.add(sim.chemistry[index])
  sim.exhibited = true
  sim.addEvent(event)

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  sim.step = stDone
  var event = blankEvent(evEnd)
  event.round = sim.roundsPlayed
  event.text = reason
  sim.addEvent(event)

proc needsAdvance*(sim: Sim): bool =
  ## True when the episode owes a structural event rather than a decision.
  if sim.done:
    return false
  case sim.step
  of stActing: sim.allActed()
  of stDone: false
  else: true

proc advance*(sim: var Sim) =
  ## Emits exactly ONE structural event and moves the step, so every
  ## recorded event has its own distinct spectator frame.
  if sim.done:
    return
  case sim.step
  of stRoundOpen:
    sim.openRound(sim.round + 1)
    sim.step = stPhaseOpen
  of stPhaseOpen:
    sim.openPhase(phLab)
    sim.step = stActing
  of stActing:
    if not sim.allActed():
      return
    if sim.phase == phLab:
      sim.openPhase(phMarket)
    elif sim.round + 1 < sim.config.rounds:
      sim.openRound(sim.round + 1)
      sim.step = stPhaseOpen
    else:
      sim.runExhibition()
      sim.step = stSettle
  of stExhibition:
    sim.runExhibition()
    sim.step = stSettle
  of stSettle:
    sim.settle("complete")
  of stDone:
    discard

proc endEarly*(sim: var Sim) =
  ## Stop now, between phases. The hosted platform keeps NOTHING from an
  ## episode that outlives its timeout, so a short honest episode always
  ## beats a long one that never lands — and the exhibition STILL runs, so
  ## a truncated episode never pays unearned publication credit.
  if sim.done:
    return
  if not sim.exhibited:
    sim.runExhibition()
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var reputation = newJArray()
  var coin = newJArray()
  var published = newJArray()
  var trueTheories = newJArray()
  var falseTheories = newJArray()
  var burned = newJArray()
  var debunks = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    reputation.add(%sim.seats[seat].reputation)
    coin.add(%sim.seats[seat].coin)
    published.add(%sim.publishedCount[seat])
    trueTheories.add(%sim.trueTheories[seat])
    falseTheories.add(%sim.falseTheories[seat])
    burned.add(%sim.burnedCount[seat])
    debunks.add(%sim.debunkCount[seat])
  %*{
    "names": names,
    "scores": scores,
    "reputation": reputation,
    "coin": coin,
    "published": published,
    "trueTheories": trueTheories,
    "falseTheories": falseTheories,
    "burned": burned,
    "debunks": debunks,
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.rounds,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc factJson*(fact: Fact): JsonNode =
  case fact.kind
  of fkMixFull:
    %*{"kind": "mixFull", "a": fact.a, "b": fact.b, "potion": $fact.potion}
  of fkMixSign:
    %*{"kind": "mixSign", "a": fact.a, "b": fact.b, "class": $fact.signClass}
  of fkNotSig:
    %*{"kind": "notSig", "x": fact.a, "sig": fact.sig,
       "sigText": sigName(fact.sig)}

proc sealJson*(sim: Sim, seal: Seal): JsonNode =
  var endorsers = newJArray()
  for endorser in seal.endorsers:
    endorsers.add(%endorser)
  %*{
    "ingredient": seal.ingredient,
    "claim": seal.claim,
    "claimText": sigName(seal.claim),
    "author": seal.author,
    "authorName": sim.names[seal.author],
    "round": seal.roundPublished,
    "endorsers": endorsers,
    "status": $seal.status,
    "vindications": seal.vindications,
    "burnedBy": seal.burnedBy,
    "roundBurned": seal.roundBurned
  }

proc gridJson(grid: Grid): JsonNode =
  result = newJArray()
  for ingredient in 0 ..< Ingredients:
    var row = newJArray()
    for sig in grid.candidateList(ingredient):
      row.add(%sig)
    result.add(row)

proc solvedCount*(grid: Grid): int =
  for ingredient in 0 ..< Ingredients:
    if grid.solved(ingredient):
      inc result

proc handJson(sim: Sim, seat: int): JsonNode =
  result = newJArray()
  var cards = sim.seats[seat].hand
  sort(cards)
  for card in cards:
    result.add(%IngredientNames[card])

proc tableStateJson*(sim: Sim): JsonNode =
  let pending = sim.pendingSeats()
  var seats = newJArray()
  for seat in 0 ..< Seats:
    var published = newJArray()
    for ingredient in sim.seats[seat].published:
      published.add(%ingredient)
    var endorsed = newJArray()
    for ingredient in sim.seats[seat].endorsed:
      endorsed.add(%ingredient)
    seats.add(%*{
      "name": sim.names[seat],
      "coin": sim.seats[seat].coin,
      "reputation": sim.seats[seat].reputation,
      "score": sim.score(seat),
      "hand": sim.handJson(seat),
      "handCount": sim.seats[seat].hand.len,
      "mortar": sim.seats[seat].mortar,
      "press": sim.seats[seat].press,
      "published": published,
      "endorsed": endorsed,
      "say": sim.seats[seat].say,
      "notes": sim.seats[seat].notes,
      "pending": seat in pending,
      "grid": gridJson(sim.grids[seat]),
      "chemistries": sim.grids[seat].chemistries,
      "solved": solvedCount(sim.grids[seat]),
      "action": sim.lastAction[seat],
      "result": sim.lastResult[seat]
    })
  var seals = newJArray()
  for seal in sim.seals:
    seals.add(sim.sealJson(seal))
  var publicFacts = newJArray()
  for fact in sim.publicFacts:
    publicFacts.add(factJson(fact))
  var ingredients = newJArray()
  for name in IngredientNames:
    ingredients.add(%name)
  var signatures = newJArray()
  for sig in 0 ..< Signatures:
    signatures.add(%sigName(sig))
  ## Demands are revealed round by round, never ahead.
  var demands = newJArray()
  for round in 0 .. min(sim.round, sim.demand.high):
    demands.add(%($sim.demand[round]))
  var initiative = newJArray()
  for seat in initiativeOrder(max(sim.round, 0)):
    initiative.add(%seat)
  ## The truth appears only at the exhibition frame, so a spectator
  ## scrubbing mid-episode cannot see the answer and the endcard can.
  var chemistry = newJArray()
  if sim.exhibited:
    for ingredient in 0 ..< Ingredients:
      chemistry.add(%sim.chemistry[ingredient])
  var bench: JsonNode = newJNull()
  if sim.bench.active:
    bench = %*{
      "seat": sim.bench.seat,
      "a": sim.bench.a,
      "b": sim.bench.b,
      "potion": $sim.bench.potion,
      "secret": sim.bench.secret
    }
  %*{
    "seats": seats,
    "seals": seals,
    "publicFacts": publicFacts,
    "bench": bench,
    "ingredients": ingredients,
    "signatures": signatures,
    "round": max(sim.round, 0),
    "rounds": sim.config.rounds,
    "roundsPlayed": sim.roundsPlayed,
    "phase": $sim.phase,
    "demand": (if sim.round >= 0 and sim.round <= sim.demand.high:
      $sim.demand[sim.round] else: ""),
    "demands": demands,
    "initiative": initiative,
    "chemistry": chemistry,
    "started": sim.round >= 0,
    "exhibited": sim.exhibited,
    "gameDone": sim.done,
    "reason": sim.reason
  }

proc observationJson*(sim: Sim, seat: int): JsonNode =
  ## The seat's whole world, and nothing else: no rival's hand, private
  ## facts, notes, grid or chemistriesLeft, and never the chemistry.
  var table = newJArray()
  for other in 0 ..< Seats:
    var published = newJArray()
    for ingredient in sim.seats[other].published:
      published.add(%ingredient)
    table.add(%*{
      "seat": other,
      "name": sim.names[other],
      "coin": sim.seats[other].coin,
      "reputation": sim.seats[other].reputation,
      "score": sim.score(other),
      "handCount": sim.seats[other].hand.len,
      "mortar": sim.seats[other].mortar,
      "press": sim.seats[other].press,
      "published": published
    })
  var seals = newJArray()
  for seal in sim.seals:
    seals.add(sim.sealJson(seal))
  var publicFacts = newJArray()
  for fact in sim.publicFacts:
    publicFacts.add(factJson(fact))
  var privateFacts = newJArray()
  for fact in sim.seats[seat].privateFacts:
    privateFacts.add(factJson(fact))
  var legal = newJArray()
  for move in sim.legalMoves(seat):
    legal.add(%move)
  var heard = newJArray()
  for other in 0 ..< Seats:
    heard.add(%(if sim.config.talk: sim.seats[other].heard else: ""))
  %*{
    "type": "state",
    "slot": seat,
    "name": sim.names[seat],
    "you": {
      "coin": sim.seats[seat].coin,
      "reputation": sim.seats[seat].reputation,
      "score": sim.score(seat),
      "hand": sim.handJson(seat),
      "mortar": sim.seats[seat].mortar,
      "press": sim.seats[seat].press,
      "grid": gridJson(sim.grids[seat]),
      "chemistries": sim.grids[seat].chemistries,
      "facts": privateFacts,
      "notes": sim.seats[seat].notes
    },
    "table": table,
    "seals": seals,
    "publicFacts": publicFacts,
    "round": max(sim.round, 0),
    "rounds": sim.config.rounds,
    "phase": $sim.phase,
    "demand": (if sim.round >= 0 and sim.round <= sim.demand.high:
      $sim.demand[sim.round] else: ""),
    "legal": legal,
    "heard": heard,
    "started": sim.round >= 0,
    "done": sim.done,
    "reason": sim.reason
  }

# ---- Event JSON -------------------------------------------------------------

proc snapshotJson(snapshot: SeatSnapshot): JsonNode =
  %*{
    "coin": snapshot.coin,
    "reputation": snapshot.reputation,
    "handCount": snapshot.handCount,
    "mortar": snapshot.mortar,
    "press": snapshot.press,
    "score": snapshot.score
  }

proc snapshotFromJson(node: JsonNode): SeatSnapshot =
  SeatSnapshot(
    coin: node{"coin"}.getInt(),
    reputation: node{"reputation"}.getInt(),
    handCount: node{"handCount"}.getInt(),
    mortar: node{"mortar"}.getBool(),
    press: node{"press"}.getBool(),
    score: node{"score"}.getFloat()
  )

proc intsJson(values: seq[int]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc intsFromJson(node: JsonNode): seq[int] =
  if node.isNil or node.kind != JArray:
    return
  for value in node:
    result.add(value.getInt())

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  case event.kind
  of evStart:
    result["chemistry"] = intsJson(event.chemistry)
    var hands = newJArray()
    for hand in event.hands:
      hands.add(intsJson(hand))
    result["hands"] = hands
  of evRound:
    result["demand"] = %($event.demand)
    result["initiative"] = intsJson(event.initiative)
    result["royalties"] = intsJson(event.royalties)
    var seats = newJArray()
    for snapshot in event.seats:
      seats.add(snapshotJson(snapshot))
    result["seats"] = seats
    result["phase"] = %($event.phase)
  of evPhase:
    result["phase"] = %($event.phase)
  of evAct:
    result["phase"] = %($event.phase)
    result["seat"] = %event.seat
    result["action"] = %event.action
    result["a"] = %event.a
    result["b"] = %event.b
    result["signature"] = %event.signature
    result["artifact"] = %event.artifact
    result["potion"] = %($event.potion)
    result["secret"] = %event.secret
    result["draws"] = intsJson(event.draws)
    result["discarded"] = intsJson(event.discarded)
    result["result"] = %event.outcome
    result["coinDelta"] = %event.coinDelta
    result["repDelta"] = %event.repDelta
    result["target"] = %event.target
    result["scripted"] = %event.scripted
    if event.say.len > 0:
      result["say"] = %event.say
  of evExhibition:
    result["chemistry"] = intsJson(event.chemistry)
    var verdicts = newJArray()
    for verdict in event.verdicts:
      verdicts.add(%*{
        "ingredient": verdict.ingredient,
        "claim": verdict.claim,
        "claimText": sigName(verdict.claim),
        "author": verdict.author,
        "endorsers": intsJson(verdict.endorsers),
        "true": verdict.correct
      })
    result["verdicts"] = verdicts
    result["repDeltas"] = intsJson(event.repDeltas)
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    phase: parseEnum[Phase](node{"phase"}.getStr("lab")),
    seat: node{"seat"}.getInt(-1),
    action: node{"action"}.getStr(""),
    a: node{"a"}.getInt(-1),
    b: node{"b"}.getInt(-1),
    signature: node{"signature"}.getInt(-1),
    artifact: node{"artifact"}.getStr(""),
    potion: parseEnum[Potion](node{"potion"}.getStr("")),
    secret: node{"secret"}.getBool(false),
    outcome: node{"result"}.getStr(""),
    coinDelta: node{"coinDelta"}.getInt(0),
    repDelta: node{"repDelta"}.getInt(0),
    target: node{"target"}.getInt(-1),
    scripted: node{"scripted"}.getBool(false),
    say: node{"say"}.getStr(""),
    text: node{"text"}.getStr(""),
    demand: parseEnum[Potion](node{"demand"}.getStr("")),
    draws: intsFromJson(node{"draws"}),
    discarded: intsFromJson(node{"discarded"}),
    initiative: intsFromJson(node{"initiative"}),
    royalties: intsFromJson(node{"royalties"}),
    chemistry: intsFromJson(node{"chemistry"}),
    repDeltas: intsFromJson(node{"repDeltas"})
  )
  if node.hasKey("hands"):
    for hand in node["hands"]:
      result.hands.add(intsFromJson(hand))
  if node.hasKey("seats"):
    for snapshot in node["seats"]:
      result.seats.add(snapshotFromJson(snapshot))
  if node.hasKey("verdicts"):
    for verdict in node["verdicts"]:
      result.verdicts.add(Verdict(
        ingredient: verdict{"ingredient"}.getInt(),
        claim: verdict{"claim"}.getInt(),
        author: verdict{"author"}.getInt(),
        endorsers: intsFromJson(verdict{"endorsers"}),
        correct: verdict{"true"}.getBool()
      ))

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the whole timeline from a recorded event log, applying
  ## every act through the real rules and ASSERTING that the seeded parts —
  ## the chemistry, the opening hands, the per-round demands and every draw
  ## — equal the re-derivation. A tampered replay raises rather than
  ## rendering a lie. frames[i] = state after events[0..<i].
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log opens with
  ## the same one, and each applied proc re-appends its own.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      var expected: seq[int]
      for index in 0 ..< Ingredients:
        expected.add(sim.chemistry[index])
      if event.chemistry.len > 0 and event.chemistry != expected:
        raise newException(CogchemistsError,
          "recorded chemistry does not match the seeded re-derivation")
      for seat in 0 ..< min(event.hands.len, Seats):
        if event.hands[seat] != sim.seats[seat].hand:
          raise newException(CogchemistsError,
            "recorded opening hand for seat " & $seat &
            " does not match the seeded re-derivation")
      sim.addEvent(event)
    of evRound:
      if event.round != sim.round + 1:
        raise newException(CogchemistsError,
          "round " & $event.round & " is out of order")
      if event.demand != poNone and event.demand != sim.demand[event.round]:
        raise newException(CogchemistsError,
          "round " & $event.round &
          " demand does not match the seeded re-derivation")
      sim.openRound(event.round)
      sim.step = stPhaseOpen
    of evPhase:
      sim.openPhase(event.phase)
      sim.step = stActing
    of evAct:
      let act = newAction(event.action, event.a, event.b, event.signature,
        event.artifact, event.say, event.text)
      if event.outcome.startsWith("rejected:"):
        sim.applyRejection(event.seat, act,
          event.outcome["rejected:".len .. ^1], event.scripted)
      else:
        sim.applyAct(event.seat, act, event.scripted)
        let derived = sim.events[^1]
        if event.draws.len > 0 and derived.draws != event.draws:
          raise newException(CogchemistsError,
            "recorded draws do not match the seeded re-derivation")
        if event.potion != poNone and derived.potion != event.potion:
          raise newException(CogchemistsError,
            "recorded potion does not match the re-derivation")
    of evExhibition:
      sim.runExhibition()
      sim.step = stSettle
      let derived = sim.events[^1]
      if event.chemistry.len > 0 and derived.chemistry != event.chemistry:
        raise newException(CogchemistsError,
          "recorded exhibition chemistry does not match the truth")
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the acts alone.
        if not sim.exhibited:
          sim.runExhibition()
        sim.settle(if event.text.len > 0: event.text else: "complete")
    result.add(sim)
