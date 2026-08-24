## Sim unit tests: setup, determinism, both action menus by hand, the debunk
## arithmetic in both directions, same-phase conflicts, the exhibition, rune
## truncation, the observation split, replay re-derivation and the endings.

import std/[json, sets, strutils, unicode, unittest]
import cogchemists/[llm, sim]

proc maxAbsInt(node: JsonNode): int =
  ## The largest magnitude any integer in a JSON tree carries.
  case node.kind
  of JInt:
    result = abs(node.getInt())
  of JArray:
    for child in node:
      result = max(result, maxAbsInt(child))
  of JObject:
    for _, child in node:
      result = max(result, maxAbsInt(child))
  else:
    result = 0

proc fixtureConfig(rounds = 6, seed = 0, talk = true,
    artifacts = true): GameConfig =
  result = defaultGameConfig()
  result.rounds = rounds
  result.seed = seed
  result.talk = talk
  result.artifacts = artifacts
  result.minBatchSpacingMs = 0
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc drive(sim: var Sim) =
  ## Runs every structural event the sim owes: round opens, phase opens,
  ## the exhibition, the settle. Exactly one event per advance.
  while (not sim.done) and sim.needsAdvance():
    sim.advance()

proc opened(config: GameConfig): Sim =
  result = initSim(config)
  result.drive()

proc passOthers(sim: var Sim, actor: int) =
  for seat in initiativeOrder(sim.round):
    if seat != actor:
      sim.applyAct(seat, newAction("pass"), true)

proc soloPhase(sim: var Sim, actor: int, act: Action) =
  ## `actor` plays `act`, everyone else passes; the phase then resolves.
  sim.applyAct(actor, act, true)
  sim.passOthers(actor)
  sim.drive()

proc allPass(sim: var Sim) =
  for seat in initiativeOrder(sim.round):
    sim.applyAct(seat, newAction("pass"), true)
  sim.drive()

proc applyOrReject(sim: var Sim, seat: int, act: Action): string =
  ## Exactly what the server does: an act the rules refuse is recorded
  ## rejected and degrades to pass.
  try:
    sim.applyAct(seat, act, true)
    return ""
  except CogchemistsError as error:
    sim.applyRejection(seat, act, error.msg, true)
    return error.msg

proc pinSeal(sim: var Sim, author, ingredient, claim: int) =
  ## Puts a standing seal on the board without spending a market phase.
  sim.seals.add(Seal(ingredient: ingredient, claim: claim, author: author,
    roundPublished: sim.round, status: sealStanding, burnedBy: -1,
    roundBurned: -1))
  sim.seats[author].published.add(ingredient)
  inc sim.publishedCount[author]

suite "setup":
  test "the chemistry is a bijection and every seat starts level":
    for seed in [0, 1, 7, 11, 42, 1234]:
      let sim = opened(fixtureConfig(seed = seed))
      var signatures = initHashSet[int]()
      for ingredient in 0 ..< Ingredients:
        signatures.incl(sim.chemistry[ingredient])
      check signatures.len == Signatures
      for seat in 0 ..< Seats:
        check sim.seats[seat].coin == StartCoin
        check sim.seats[seat].reputation == StartReputation
        check sim.seats[seat].hand.len == StartHand
      check sim.demand.len == sim.config.rounds
      for potion in sim.demand:
        check potion != poMud
        check potion in ColouredPotions
      check sim.pendingSeats().len == Seats
      var aliases = initHashSet[string]()
      for name in sim.names:
        aliases.incl(name)
      check aliases.len == Seats

  test "the opening events are start, round, phase":
    var sim = initSim(fixtureConfig(seed = 5))
    check sim.events.len == 1
    check sim.events[0].kind == evStart
    sim.drive()
    check sim.events.len == 3
    check sim.events[1].kind == evRound
    check sim.events[2].kind == evPhase
    check sim.events[2].phase == phLab

suite "determinism":
  test "the same seed reproduces the chemistry, demands, aliases and draws":
    for seed in [0, 3, 11, 99]:
      let a = opened(fixtureConfig(seed = seed))
      let b = opened(fixtureConfig(seed = seed))
      check a.chemistry == b.chemistry
      check a.demand == b.demand
      check a.names == b.names
      for seat in 0 ..< Seats:
        check a.seats[seat].hand == b.seats[seat].hand

  test "different seeds give different chemistries":
    var seen = initHashSet[string]()
    for seed in 0 ..< 20:
      let sim = opened(fixtureConfig(seed = seed))
      var text = ""
      for ingredient in 0 ..< Ingredients:
        text.add($sim.chemistry[ingredient])
      seen.incl(text)
    check seen.len > 1

suite "initiative":
  test "the order rotates and every seat leads exactly twice in eight rounds":
    var leads: array[Seats, int]
    for round in 0 ..< 8:
      let order = initiativeOrder(round)
      var seen = initHashSet[int]()
      for index, seat in order:
        check seat == (index + round) mod Seats
        seen.incl(seat)
      check seen.len == Seats
      inc leads[order[0]]
    for seat in 0 ..< Seats:
      check leads[seat] == 2

suite "lab actions":
  test "forage draws two and never exceeds the hand cap":
    var sim = opened(fixtureConfig(seed = 2))
    let before = sim.seats[0].hand.len
    sim.soloPhase(0, newAction("forage"))
    var event: GameEvent
    for candidate in sim.events:
      if candidate.kind == evAct and candidate.seat == 0:
        event = candidate
    check event.draws.len == ForageDraw
    check sim.seats[0].hand.len == before + ForageDraw
    ## A draw into a full hand is discarded and recorded as such.
    sim.seats[0].hand = @[0, 1, 2, 3, 4, 5]
    sim.soloPhase(0, newAction("pass"))         # burn the market phase
    sim.soloPhase(0, newAction("forage"))
    check sim.seats[0].hand.len == HandCap
    for candidate in sim.events:
      if candidate.kind == evAct and candidate.seat == 0 and
          candidate.action == "forage" and candidate.round == 1:
        check candidate.discarded.len == ForageDraw

  test "test_student costs a coin, burns both cards and stays private":
    var sim = opened(fixtureConfig(seed = 4))
    sim.seats[0].hand = @[0, 1, 2]
    sim.soloPhase(0, newAction("test_student", 0, 1))
    check sim.seats[0].coin == StartCoin - StudentCost
    check sim.seats[0].hand == @[2]
    check sim.seats[0].privateFacts.len == 1
    check sim.seats[0].privateFacts[0].kind == fkMixFull
    check sim.seats[0].privateFacts[0].potion ==
      sim.chemistry.mix(0, 1)
    check sim.publicFacts.len == 0

  test "the Magic Mortar spares the second card":
    var sim = opened(fixtureConfig(seed = 4))
    sim.seats[0].hand = @[0, 1, 2]
    sim.seats[0].mortar = true
    sim.soloPhase(0, newAction("test_student", 0, 1))
    check sim.seats[0].hand.len == 2
    check 1 in sim.seats[0].hand

  test "test_self leaks the sign class and moves reputation":
    for seed in 0 ..< 12:
      var sim = opened(fixtureConfig(seed = seed))
      sim.seats[0].hand = @[0, 1]
      let potion = sim.chemistry.mix(0, 1)
      sim.soloPhase(0, newAction("test_self", 0, 1))
      check sim.seats[0].coin == StartCoin
      check sim.seats[0].privateFacts.len == 1
      check sim.publicFacts.len == 1
      check sim.publicFacts[0].kind == fkMixSign
      check sim.publicFacts[0].signClass == signClassOf(potion)
      let expected =
        case signClassOf(potion)
        of scPositive: StartReputation + DrinkPositiveRep
        of scNegative: StartReputation + DrinkNegativeRep
        of scMud: StartReputation
      check sim.seats[0].reputation == expected

  test "transmute pays two and pass pays one":
    var sim = opened(fixtureConfig(seed = 6))
    sim.seats[0].hand = @[3, 4]
    sim.soloPhase(0, newAction("transmute", 3))
    check sim.seats[0].coin == StartCoin + TransmuteCoin
    check sim.seats[0].hand == @[4]
    check sim.seats[1].coin == StartCoin + PassCoin

suite "market actions":
  test "sell pays on a hit and still pays on a miss":
    var sim = opened(fixtureConfig(seed = 8))
    sim.allPass()                       # through the lab phase
    ## Find a pair that makes exactly what the adventurer asked for.
    var hitA = -1
    var hitB = -1
    for a in 0 ..< Ingredients:
      for b in a + 1 ..< Ingredients:
        if sim.chemistry.mix(a, b) == sim.demand[sim.round] and hitA < 0:
          hitA = a
          hitB = b
    check hitA >= 0
    sim.seats[0].hand = @[hitA, hitB]
    let coinBefore = sim.seats[0].coin
    sim.soloPhase(0, newAction("sell", hitA, hitB))
    check sim.seats[0].coin == coinBefore + SellHitCoin
    check sim.seats[0].reputation == StartReputation + SellHitRep
    check sim.seats[0].hand.len == 0
    check sim.publicFacts.len == 1
    check sim.publicFacts[0].kind == fkMixFull

  test "a miss pays two coin and costs a reputation":
    var sim = opened(fixtureConfig(seed = 9))
    sim.allPass()
    var missA = -1
    var missB = -1
    for a in 0 ..< Ingredients:
      for b in a + 1 ..< Ingredients:
        if sim.chemistry.mix(a, b) != sim.demand[sim.round] and missA < 0:
          missA = a
          missB = b
    check missA >= 0
    sim.seats[0].hand = @[missA, missB]
    let coinBefore = sim.seats[0].coin
    sim.soloPhase(0, newAction("sell", missA, missB))
    check sim.seats[0].coin == coinBefore + SellMissCoin
    check sim.seats[0].reputation == StartReputation + SellMissRep

  test "publish pins a seal, pays credit, and is illegal twice":
    var sim = opened(fixtureConfig(seed = 10))
    sim.allPass()
    let coinBefore = sim.seats[0].coin
    sim.applyAct(0, newAction("publish", 2, signature = 5), true)
    check sim.seats[0].coin == coinBefore - PublishCost
    check sim.seats[0].reputation == StartReputation + PublishRep
    check sim.seals.len == 1
    check sim.seals[0].status == sealStanding
    check sim.sealIndex(2) == 0
    check sim.checkAct(1, newAction("publish", 2, signature = 1)) ==
      "already_claimed"

  test "the Printing Press pays three":
    var sim = opened(fixtureConfig(seed = 10))
    sim.seats[0].press = true
    sim.allPass()
    sim.applyAct(0, newAction("publish", 2, signature = 5), true)
    check sim.seats[0].reputation == StartReputation + PressPublishRep

  test "endorse moves a coin to the author and never repeats":
    var sim = opened(fixtureConfig(seed = 12))
    sim.allPass()
    sim.pinSeal(0, 4, 3)
    check sim.checkAct(0, newAction("endorse", 4)) == "own_theory"
    check sim.checkAct(1, newAction("endorse", 4)) == ""
    let authorCoin = sim.seats[0].coin
    let endorserCoin = sim.seats[1].coin
    sim.applyAct(1, newAction("endorse", 4), true)
    check sim.seats[0].coin == authorCoin + EndorseCost
    check sim.seats[1].coin == endorserCoin - EndorseCost
    check sim.seals[0].endorsers == @[1]
    check sim.checkAct(1, newAction("endorse", 4)) == "already_acted"
    sim.seats[1].hand = @[0]
    sim.acted[1] = false
    check sim.checkAct(1, newAction("endorse", 4)) == "already_endorsed"

  test "buying an artifact is once each and never on credit":
    var sim = opened(fixtureConfig(seed = 13))
    sim.allPass()
    sim.seats[0].coin = 3
    check sim.checkAct(0, newAction("buy", artifact = "mortar")) == "no_coin"
    sim.seats[0].coin = MortarCost
    sim.applyAct(0, newAction("buy", artifact = "mortar"), true)
    check sim.seats[0].mortar
    check sim.seats[0].coin == 0
    sim.acted[0] = false
    sim.seats[0].coin = 99
    check sim.checkAct(0, newAction("buy", artifact = "mortar")) ==
      "already_owned"

  test "unaffordable actions are absent from legalMoves":
    var sim = opened(fixtureConfig(seed = 14))
    sim.allPass()
    sim.seats[0].coin = 0
    sim.seats[0].hand = @[0, 1]
    let moves = sim.legalMoves(0)
    for move in moves:
      check not move.startsWith("publish")
      check not move.startsWith("buy")
      check not move.startsWith("endorse")
    check "pass" in moves
    check ("sell a=\"" & IngredientNames[0] & "\" b=\"" &
      IngredientNames[1] & "\"") in moves

suite "the debunk":
  test "a demonstration the claim mispredicts burns the seal":
    var sim = opened(fixtureConfig(seed = 15))
    sim.chemistry = [0, 1, 2, 3, 4, 5, 6, 7]
    sim.allPass()
    ## Nightcap is really R-G-B- (0); the seal claims R-G-B+ (1). Mixed with
    ## Emberroot (1) the truth is BLUE+ but the claim predicts MUD.
    sim.pinSeal(0, 0, 1)
    sim.seals[0].endorsers = @[2]
    sim.seats[1].hand = @[1]
    let authorRep = sim.seats[0].reputation
    let debunkerRep = sim.seats[1].reputation
    let endorserRep = sim.seats[2].reputation
    sim.applyAct(1, newAction("debunk", 0, 1), true)
    check sim.seals[0].status == sealBurned
    check sim.seals[0].burnedBy == 1
    check sim.seats[0].reputation == authorRep + BurnAuthorRep
    check sim.seats[1].reputation == debunkerRep + BurnDebunkerRep
    check sim.seats[2].reputation == endorserRep + BurnEndorserRep
    check sim.sealIndex(0) == -1          # publishable again
    var sawNotSig = false
    var sawMixFull = false
    for fact in sim.publicFacts:
      if fact.kind == fkNotSig and fact.a == 0 and fact.sig == 1:
        sawNotSig = true
      if fact.kind == fkMixFull and fact.a == 0 and fact.b == 1:
        check fact.potion == poBluePos
        sawMixFull = true
    check sawNotSig
    check sawMixFull

  test "a wrong claim this reagent cannot expose survives, and costs the attacker":
    var sim = opened(fixtureConfig(seed = 16))
    sim.chemistry = [0, 1, 2, 3, 4, 5, 6, 7]
    sim.allPass()
    ## Nightcap is really R-G-B- (0); the seal claims R+G-B+ (5), which is
    ## WRONG — but mixed with Widow's Salt (3, R-G+B+) both the truth and
    ## the claim give MUD, so this demonstration cannot see the error.
    check mixSignatures(0, 3) == poMud
    check mixSignatures(5, 3) == poMud
    sim.pinSeal(0, 0, 5)
    sim.seats[1].hand = @[3]
    let authorRep = sim.seats[0].reputation
    let debunkerRep = sim.seats[1].reputation
    sim.applyAct(1, newAction("debunk", 0, 3), true)
    check sim.seals[0].status == sealStanding
    check sim.seals[0].vindications == 1
    check sim.seats[1].reputation == debunkerRep + SurviveDebunkerRep
    check sim.seats[0].reputation == authorRep + SurviveAuthorRep

suite "same-phase conflicts":
  test "the earlier initiative wins the ingredient":
    var sim = opened(fixtureConfig(seed = 17))
    sim.allPass()
    let order = initiativeOrder(sim.round)
    let first = order[0]
    let second = order[1]
    check sim.applyOrReject(first, newAction("publish", 3, signature = 2)) ==
      ""
    let stipend = sim.seats[second].coin
    check sim.applyOrReject(second, newAction("publish", 3, signature = 6)) ==
      "already_claimed"
    check sim.seats[second].coin == stipend + PassCoin
    check sim.seals.len == 1
    var rejected: GameEvent
    for event in sim.events:
      if event.kind == evAct and event.seat == second:
        rejected = event
    check rejected.outcome == "rejected:already_claimed"
    check rejected.action == "publish"

  test "a debunk of a seal that has just burned is rejected":
    var sim = opened(fixtureConfig(seed = 18))
    sim.chemistry = [0, 1, 2, 3, 4, 5, 6, 7]
    sim.allPass()
    sim.pinSeal(3, 0, 1)
    let order = initiativeOrder(sim.round)
    var attackers: seq[int]
    for seat in order:
      if seat != 3:
        attackers.add(seat)
    sim.seats[attackers[0]].hand = @[1]
    sim.seats[attackers[1]].hand = @[1]
    check sim.applyOrReject(attackers[0], newAction("debunk", 0, 1)) == ""
    check sim.seals[0].status == sealBurned
    check sim.applyOrReject(attackers[1], newAction("debunk", 0, 1)) ==
      "no_such_theory"
    ## The sim is still legal afterwards: the rejected seat acted and took
    ## the stipend, and the phase can still resolve.
    for seat in order:
      if not sim.acted[seat]:
        sim.applyAct(seat, newAction("pass"), true)
    check sim.allActed()
    sim.drive()
    check not sim.done

suite "the exhibition":
  test "true seals pay and false seals cost, and burned seals are not rescored":
    var sim = opened(fixtureConfig(rounds = MinRounds, seed = 19))
    sim.chemistry = [0, 1, 2, 3, 4, 5, 6, 7]
    sim.pinSeal(0, 0, 0)                    # true
    sim.seals[^1].endorsers = @[1]
    sim.pinSeal(2, 4, 7)                    # false
    sim.seals[^1].endorsers = @[3]
    sim.pinSeal(1, 6, 2)                    # burned before the exhibition
    sim.seals[^1].status = sealBurned
    sim.seals[^1].burnedBy = 0
    let before: array[Seats, int] = [sim.seats[0].reputation,
      sim.seats[1].reputation, sim.seats[2].reputation,
      sim.seats[3].reputation]
    sim.endEarly()
    check sim.reason == "deadline"
    check sim.seats[0].reputation == before[0] + ExhibitTrueAuthor
    check sim.seats[1].reputation == before[1] + ExhibitTrueEndorser
    check sim.seats[2].reputation == before[2] + ExhibitFalseAuthor
    check sim.seats[3].reputation == before[3] + ExhibitFalseEndorser
    check sim.trueTheories[0] == 1
    check sim.falseTheories[2] == 1
    check sim.trueTheories[1] == 0
    check sim.falseTheories[1] == 0
    var exhibition: GameEvent
    for event in sim.events:
      if event.kind == evExhibition:
        exhibition = event
    check exhibition.verdicts.len == 2
    check exhibition.chemistry.len == Ingredients
    for ingredient in 0 ..< Ingredients:
      check exhibition.chemistry[ingredient] == sim.chemistry[ingredient]

  test "a deadline exhibition scores exactly the seals standing then":
    var sim = opened(fixtureConfig(rounds = 6, seed = 20))
    sim.chemistry = [0, 1, 2, 3, 4, 5, 6, 7]
    for _ in 0 ..< 2:
      sim.allPass()             # lab
      sim.allPass()             # market
    check sim.roundsPlayed == 2
    sim.pinSeal(0, 5, 5)        # true
    sim.endEarly()
    check sim.reason == "deadline"
    check sim.trueTheories[0] == 1
    check sim.resultsJson()["rounds"].getInt() == 2
    check sim.resultsJson()["maxRounds"].getInt() == 6

suite "rune truncation":
  test "say and notes cut on rune boundaries, never bytes":
    var sim = opened(fixtureConfig(seed = 21))
    let longSay = "é".repeat(400)
    let shortNotes = "ü".repeat(400)
    var act = newAction("pass")
    act.say = longSay
    act.notes = shortNotes
    sim.applyAct(0, act, true)
    check sim.seats[0].say.runeLen == MaxSayLen
    check sim.seats[0].say.validateUtf8() == -1
    check sim.seats[0].notes.runeLen == 400
    sim.acted[0] = false
    var act2 = newAction("pass")
    act2.notes = "ø".repeat(800)
    sim.applyAct(0, act2, true)
    check sim.seats[0].notes.runeLen == MaxNotesLen
    check sim.seats[0].notes.validateUtf8() == -1
    for event in sim.events:
      check event.say.validateUtf8() == -1
      check event.text.validateUtf8() == -1
    ## The whole replay must survive a strict UTF-8 JSON parse.
    var payload = newJArray()
    for event in sim.events:
      payload.add(event.eventToJson())
    check ($payload).validateUtf8() == -1
    discard parseJson($payload)

  test "with talk off every say is empty":
    var sim = opened(fixtureConfig(seed = 22, talk = false))
    var act = newAction("pass")
    act.say = "I would not bet against Nightcap."
    sim.applyAct(0, act, true)
    check sim.seats[0].say == ""
    for event in sim.events:
      check event.say == ""

suite "wasm integer width":
  test "no integer in a maximal episode can overflow 32-bit int":
    var sim = opened(fixtureConfig(rounds = MaxRounds, seed = 23))
    while not sim.done:
      for seat in initiativeOrder(sim.round):
        sim.applyAct(seat, newAction(
          if sim.phase == phLab: "forage" else: "pass"), true)
      sim.drive()
      for seat in 0 ..< Seats:
        check abs(sim.seats[seat].coin) < 100_000
        check abs(sim.seats[seat].reputation) < 100_000
        check sim.grids[seat].chemistries <= TotalChemistries
    for event in sim.events:
      check maxAbsInt(event.eventToJson()) < 100_000
    check maxAbsInt(sim.tableStateJson()) < 100_000
    check maxAbsInt(sim.resultsJson()) < 100_000

suite "the observation split":
  test "no rival's private world reaches a seat's frame or its prompt":
    var sim = opened(fixtureConfig(rounds = 4, seed = 24))
    var published = false
    var phase = 0
    while not sim.done and phase < 6:
      for seat in 0 ..< Seats:
        let frame = sim.observationJson(seat)
        let text = $frame
        let prompt = sim.userPrompt(seat, "")
        ## The truth never crosses this socket.
        check not frame.hasKey("chemistry")
        for other in frame["table"]:
          for forbidden in ["hand", "grid", "notes", "facts", "chemistries"]:
            check not other.hasKey(forbidden)
        ## The seat's own grid IS there, exactly as the sim computed it.
        for ingredient in 0 ..< Ingredients:
          check frame["you"]["grid"][ingredient].len ==
            card(sim.grids[seat].candidates[ingredient])
        check ($sim.grids[seat].chemistries &
          " chemistries still possible") in prompt
        for other in 0 ..< Seats:
          if other == seat:
            continue
          if sim.seats[other].notes.len > 0:
            check sim.seats[other].notes notin text
            check sim.seats[other].notes notin prompt
        ## An ingredient this seat has not solved is never marked SOLVED.
        for ingredient in 0 ..< Ingredients:
          if card(sim.grids[seat].candidates[ingredient]) > 1:
            check (IngredientNames[ingredient].alignLeft(14) & "SOLVED") notin
              prompt
        ## LEGAL MOVES names every referent the reply schema can use.
        var joined = ""
        for move in sim.legalMoves(seat):
          joined.add(move & "\n")
        for held in sim.seats[seat].hand:
          check IngredientNames[held] in joined
        if sim.phase == phMarket:
          for seal in sim.seals:
            if seal.status == sealStanding and seal.author != seat:
              check IngredientNames[seal.ingredient] in joined
          if sim.seats[seat].coin >= MortarCost and
              not sim.seats[seat].mortar:
            check "artifact=\"mortar\"" in joined
      for seat in initiativeOrder(sim.round):
        var act = newAction("pass")
        if sim.phase == phMarket and seat == 0 and not published:
          act = newAction("publish", 1, signature = 4)
          published = true
        act.notes = "PRIVATE-NOTE-OF-SEAT-" & $seat & "-PHASE-" & $phase
        act.say = "REMARK-" & $seat
        if sim.checkAct(seat, act).len != 0:
          act = newAction("pass")
          act.notes = "PRIVATE-NOTE-OF-SEAT-" & $seat & "-PHASE-" & $phase
        sim.applyAct(seat, act, true)
      sim.drive()
      inc phase
    check published

suite "replay":
  test "the timeline re-derives frame for frame":
    let config = fixtureConfig(rounds = 4, seed = 25)
    var sim = opened(config)
    while not sim.done:
      for seat in initiativeOrder(sim.round):
        var act = newAction("pass")
        if sim.phase == phLab:
          act = newAction("forage")
        act.notes = "n" & $seat
        act.say = "s" & $seat
        sim.applyAct(seat, act, true)
      sim.drive()
    let frames = replayMatch(config, sim.events)
    check frames.len == sim.events.len + 1
    check $frames[^1].tableStateJson() == $sim.tableStateJson()
    for seat in 0 ..< Seats:
      check frames[^1].grids[seat].chemistries ==
        sim.grids[seat].chemistries
      check frames[^1].grids[seat].candidates == sim.grids[seat].candidates

  test "every event kind round-trips through JSON field by field":
    let config = fixtureConfig(rounds = MinRounds, seed = 26)
    var sim = opened(config)
    while not sim.done:
      for seat in initiativeOrder(sim.round):
        var act = newAction("pass")
        if sim.phase == phLab:
          act = newAction("forage")
        act.say = "hello " & $seat
        act.notes = "notes " & $seat
        sim.applyAct(seat, act, true)
      sim.drive()
    var kinds = initHashSet[EventKind]()
    for event in sim.events:
      kinds.incl(event.kind)
      let back = eventFromJson(event.eventToJson())
      check back.kind == event.kind
      check back.round == event.round
      check back.seat == event.seat
      check back.action == event.action
      check back.a == event.a
      check back.b == event.b
      check back.signature == event.signature
      check back.artifact == event.artifact
      check back.potion == event.potion
      check back.secret == event.secret
      check back.draws == event.draws
      check back.discarded == event.discarded
      check back.outcome == event.outcome
      check back.coinDelta == event.coinDelta
      check back.repDelta == event.repDelta
      check back.target == event.target
      check back.scripted == event.scripted
      check back.say == event.say
      check back.text == event.text
      check back.demand == event.demand
      check back.initiative == event.initiative
      check back.royalties == event.royalties
      check back.chemistry == event.chemistry
      check back.hands == event.hands
      check back.repDeltas == event.repDeltas
      check back.verdicts.len == event.verdicts.len
      if event.kind in {evPhase, evAct, evRound}:
        check back.phase == event.phase
      check back.seats.len == event.seats.len
    for kind in EventKind:
      check kind in kinds

  test "a tampered replay raises instead of rendering a lie":
    let config = fixtureConfig(rounds = MinRounds, seed = 27)
    var sim = opened(config)
    while not sim.done:
      for seat in initiativeOrder(sim.round):
        sim.applyAct(seat, newAction(
          if sim.phase == phLab: "forage" else: "pass"), true)
      sim.drive()
    discard replayMatch(config, sim.events)      # the honest log is fine

    var badChemistry = sim.events
    badChemistry[0].chemistry[0] = (badChemistry[0].chemistry[0] + 1) mod 8
    expect CogchemistsError:
      discard replayMatch(config, badChemistry)

    var badDraws = sim.events
    for index in 0 ..< badDraws.len:
      if badDraws[index].kind == evAct and badDraws[index].draws.len > 0:
        badDraws[index].draws[0] = (badDraws[index].draws[0] + 1) mod 8
        break
    expect CogchemistsError:
      discard replayMatch(config, badDraws)

    var badDemand = sim.events
    for index in 0 ..< badDemand.len:
      if badDemand[index].kind == evRound:
        badDemand[index].demand =
          if badDemand[index].demand == poRedPos: poBlueNeg else: poRedPos
        break
    expect CogchemistsError:
      discard replayMatch(config, badDemand)

  test "a deadline ending re-derives as deadline, not complete":
    let config = fixtureConfig(rounds = 6, seed = 28)
    var sim = opened(config)
    for _ in 0 ..< 2:
      sim.allPass()
      sim.allPass()
    sim.endEarly()
    check sim.reason == "deadline"
    let frames = replayMatch(config, sim.events)
    check frames[^1].reason == "deadline"
    check frames[^1].done
    check frames[^1].roundsPlayed == 2

suite "endings":
  test "a full episode ends complete and refuses further acts":
    var sim = opened(fixtureConfig(rounds = MinRounds, seed = 29))
    while not sim.done:
      sim.allPass()
    check sim.reason == "complete"
    check sim.roundsPlayed == MinRounds
    check sim.events[^1].kind == evEnd
    check sim.events[^2].kind == evExhibition
    expect CogchemistsError:
      sim.applyAct(0, newAction("pass"), true)
    check sim.resultsJson()["reason"].getStr() == "complete"

  test "endEarly is idempotent and runs the exhibition exactly once":
    var sim = opened(fixtureConfig(rounds = 6, seed = 30))
    sim.allPass()
    sim.endEarly()
    sim.endEarly()
    sim.endEarly()
    var exhibitions = 0
    var ends = 0
    for event in sim.events:
      if event.kind == evExhibition: inc exhibitions
      if event.kind == evEnd: inc ends
    check exhibitions == 1
    check ends == 1
    check sim.reason == "deadline"
    check sim.resultsJson()["reason"].getStr() in ["complete", "deadline"]
