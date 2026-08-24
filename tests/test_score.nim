## Scoring: the formula, its sign, the worked landmark from the design note,
## the do-nothing floor, and the eleven-point gap a single wax seal is worth.

import std/[json, math, unittest]
import cogchemists/sim

proc fixtureConfig(rounds = 6, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.rounds = rounds
  result.seed = seed
  result.minBatchSpacingMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc drive(sim: var Sim) =
  while (not sim.done) and sim.needsAdvance():
    sim.advance()

proc actAll(sim: var Sim, actor: int, act: Action) =
  for seat in initiativeOrder(sim.round):
    if seat == actor:
      sim.applyAct(seat, act, true)
    else:
      sim.applyAct(seat, newAction("pass"), true)
  sim.drive()

proc hitPair(sim: Sim): (int, int) =
  ## A pair that makes exactly what this round's adventurer asked for.
  for a in 0 ..< Ingredients:
    for b in a + 1 ..< Ingredients:
      if sim.chemistry.mix(a, b) == sim.demand[sim.round]:
        return (a, b)
  (-1, -1)

proc landmark(claimTruth: bool): Sim =
  ## The design note's worked landmark, played out move by move:
  ## test_student, publish, five round-opens of royalties, a forage, a hit
  ## sale, eight passes, and the exhibition.
  result = initSim(fixtureConfig(rounds = 6, seed = 33))
  result.drive()
  result.seats[0].hand = @[0, 1, 2]
  ## Round 0 LAB: pay the student. coin 4 -> 3.
  result.actAll(0, newAction("test_student", 0, 1))
  ## Round 0 MARKET: publish Nightcap. coin 3 -> 2, reputation 10 -> 12.
  let truth = result.chemistry[0]
  let claim = if claimTruth: truth else: (truth + 1) mod Signatures
  result.actAll(0, newAction("publish", 0, signature = claim))
  ## Round 1 LAB: forage. Royalties at the round open have paid 1 coin.
  result.actAll(0, newAction("forage"))
  ## Round 1 MARKET: sell a hit. +6 coin, +1 reputation.
  let pair = result.hitPair()
  doAssert pair[0] >= 0
  result.seats[0].hand = @[pair[0], pair[1]]
  result.actAll(0, newAction("sell", pair[0], pair[1]))
  ## Rounds 2-5: eight passes, four more round-opens of royalties.
  while not result.done:
    result.actAll(0, newAction("pass"))

suite "scoring":
  test "score is reputation plus a fifth of the coin":
    var sim = initSim(fixtureConfig(seed = 31))
    sim.drive()
    sim.seats[0].reputation = 13
    sim.seats[0].coin = 7
    check abs(sim.score(0) - 14.4) < 1e-9
    sim.seats[1].reputation = -4
    sim.seats[1].coin = 1
    ## A score may be negative; that is the sign, not a bug.
    check abs(sim.score(1) - (-3.8)) < 1e-9

  test "the worked landmark reproduces 22.2":
    let sim = landmark(claimTruth = true)
    check sim.reason == "complete"
    check sim.seats[0].reputation == 18
    check sim.seats[0].coin == 21
    check abs(sim.score(0) - 22.2) < 1e-9
    check sim.trueTheories[0] == 1
    check sim.falseTheories[0] == 0
    check sim.publishedCount[0] == 1

  test "the do-nothing floor is 13.2":
    let sim = landmark(claimTruth = true)
    ## Seat 1 passed all twelve phases and did nothing else.
    check sim.seats[1].reputation == StartReputation
    check sim.seats[1].coin == StartCoin + 12 * PassCoin
    check abs(sim.score(1) - 13.2) < 1e-9

  test "one false seal costs eleven points against one true seal":
    let good = landmark(claimTruth = true)
    let bad = landmark(claimTruth = false)
    check good.seats[0].coin == bad.seats[0].coin
    check good.seats[0].reputation - bad.seats[0].reputation ==
      ExhibitTrueAuthor - ExhibitFalseAuthor
    check abs((good.score(0) - bad.score(0)) - 11.0) < 1e-9
    check bad.falseTheories[0] == 1

  test "resultsJson agrees with the final frame":
    let sim = landmark(claimTruth = true)
    let results = sim.resultsJson()
    for key in ["names", "scores", "reputation", "coin", "published",
        "trueTheories", "falseTheories", "burned", "debunks"]:
      check results[key].len == Seats
    for seat in 0 ..< Seats:
      check results["reputation"][seat].getInt() == sim.seats[seat].reputation
      check results["coin"][seat].getInt() == sim.seats[seat].coin
      check abs(results["scores"][seat].getFloat() - sim.score(seat)) < 1e-9
      check results["names"][seat].getStr() ==
        sim.config.players[seat].name
    check results["rounds"].getInt() == 6
    check results["maxRounds"].getInt() == 6
    check results["reason"].getStr() == "complete"
    ## Higher is better, and the landmark seat leads the do-nothing seat.
    check results["scores"][0].getFloat() > results["scores"][1].getFloat()
