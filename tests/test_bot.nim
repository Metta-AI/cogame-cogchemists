## The scripted baselines must play whole episodes without ever proposing an
## illegal action — they are both the no-credentials fallback (offline
## certification, the docker smoke) and fieldable policies. The assayer must
## also actually be worth beating, and the reply parser must read every shape
## the schema documents.

import std/[json, monotimes, strutils, times, unicode, unittest]
import cogchemists/[llm, sim]

const
  EpisodeBudgetMs = when defined(release): 2000 else: 20000
  DisabledBudgetMs = when defined(release): 5000 else: 30000

proc fixture(seed: int, rounds = 6, talk = true): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.talk = talk
  result.minBatchSpacingMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc drive(sim: var Sim) =
  while (not sim.done) and sim.needsAdvance():
    sim.advance()

type Tally = object
  unsolvedPublishes: int
  falseAtExhibition: int
  burned: int

proc playScripted(config: GameConfig, kinds: array[Seats, ScriptKind],
    tally: var Tally): Sim =
  result = initSim(config)
  result.drive()
  while not result.done:
    for seat in initiativeOrder(result.round):
      let decision = scriptedAction(result, seat, kinds[seat])
      ## The bounded/legal assertion: the bot's action must be a member of
      ## the legal set AT THE MOMENT IT IS PLAYED, not merely survive
      ## applyAct. doAssert, not check: this runs outside the test body, and
      ## a failure has to abort with the offending move rather than tick a
      ## counter nobody reads.
      doAssert showAct(decision) in result.legalMoves(seat),
        "illegal scripted move: " & showAct(decision) & " (seat " & $seat &
        ", round " & $result.round & ", " & $result.phase & ")"
      doAssert decision.say.len == 0, "a scripted seat never talks"
      doAssert decision.notes.len == 0, "a scripted seat never takes notes"
      if decision.action == "publish" and
          not result.grids[seat].solved(decision.a):
        inc tally.unsolvedPublishes
      ## applyAct raises on anything illegal and would fail this test.
      result.applyAct(seat, decision, true)
      doAssert result.seats[seat].coin >= 0, "coin went negative"
      doAssert result.seats[seat].hand.len <= HandCap, "hand cap exceeded"
    result.drive()
  for seat in 0 ..< Seats:
    tally.falseAtExhibition += result.falseTheories[seat]
    tally.burned += result.burnedCount[seat]

proc meanScore(sim: Sim): float =
  for seat in 0 ..< Seats:
    result += sim.score(seat)
  result / Seats.float

suite "legality and boundedness":
  test "every scripted table completes without an illegal action":
    let mixes: array[3, array[Seats, ScriptKind]] = [
      [skAssayer, skAssayer, skAssayer, skAssayer],
      [skQuack, skQuack, skQuack, skQuack],
      [skAssayer, skQuack, skAssayer, skQuack]
    ]
    for seed in [1, 7, 11, 42]:
      for kinds in mixes:
        var tally = Tally()
        let started = getMonoTime()
        let sim = playScripted(fixture(seed), kinds, tally)
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.roundsPlayed == sim.config.rounds
        ## No seat may name a card it does not hold, and no ingredient may
        ## carry two standing seals.
        var standing: array[Ingredients, int]
        for seal in sim.seals:
          if seal.status == sealStanding:
            inc standing[seal.ingredient]
        for ingredient in 0 ..< Ingredients:
          check standing[ingredient] <= 1
        check elapsed < EpisodeBudgetMs

suite "baseline behaviour":
  test "the assayer publishes only what it has solved":
    for seed in [1, 7, 11, 42]:
      var tally = Tally()
      let sim = playScripted(fixture(seed),
        [skAssayer, skAssayer, skAssayer, skAssayer], tally)
      ## A solved ingredient's one candidate must BE the truth, so a
      ## disciplined publisher can never be proved wrong.
      check tally.unsolvedPublishes == 0
      for seat in 0 ..< Seats:
        check sim.falseTheories[seat] == 0
        check sim.burnedCount[seat] == 0

  test "the quack publishes on hunches and pays for it":
    var unsolved = 0
    var punished = 0
    for seed in [1, 7, 11, 42]:
      var tally = Tally()
      discard playScripted(fixture(seed),
        [skQuack, skQuack, skQuack, skQuack], tally)
      check tally.unsolvedPublishes >= 1
      unsolved += tally.unsolvedPublishes
      punished += tally.falseAtExhibition + tally.burned
    echo "  quack: ", unsolved, " unsolved seals, ", punished,
      " proved false or burned"
    check punished >= 1

  test "an assayer table beats a quack table on the same seed":
    for seed in [1, 7, 11, 42]:
      var tallyA = Tally()
      var tallyQ = Tally()
      let assayers = playScripted(fixture(seed),
        [skAssayer, skAssayer, skAssayer, skAssayer], tallyA)
      let quacks = playScripted(fixture(seed),
        [skQuack, skQuack, skQuack, skQuack], tallyQ)
      echo "  seed ", seed, ": assayer mean ", meanScore(assayers),
        " vs quack mean ", meanScore(quacks)
      check meanScore(assayers) > meanScore(quacks)

suite "the no-credentials fallback":
  test "a disabled client decides scripted with no network wait":
    ## The environment of a CI runner has no credentials, which is exactly
    ## the offline-certification path this asserts.
    var config = fixture(3)
    config.minBatchSpacingMs = 10_000
    let client = newLlmClient(config)
    check client.disabled
    ## The spacing floor is skipped entirely when the client is disabled.
    check client.minBatchSpacingMs == 0
    var sim = initSim(config)
    sim.drive()
    let started = getMonoTime()
    while not sim.done:
      let seats = sim.pendingSeats()
      check seats.len == Seats
      let decisions = client.decideAll(sim, seats,
        newSeq[string](Seats), newSeq[ScriptKind](Seats))
      check decisions.len == Seats
      for seat in initiativeOrder(sim.round):
        var position = -1
        for index, candidate in seats:
          if candidate == seat:
            position = index
        sim.applyAct(seat, decisions[position], true)
      sim.drive()
    let elapsed = (getMonoTime() - started).inMilliseconds
    echo "  disabled 6-round episode: ", elapsed, " ms"
    check sim.reason == "complete"
    check elapsed < DisabledBudgetMs

suite "reply parsing":
  test "the documented shapes parse and the caps hold":
    var sim = initSim(fixture(5))
    sim.drive()
    sim.seats[0].hand = @[0, 6]
    let reply = parseJson("""{"action":"test_student","a":"Nightcap",
      "b":"Sunmoss","signature":"","artifact":"","say":"a hunch",
      "notes":"keep going"}""")
    let action = parseReply(sim, 0, reply)
    check action.action == "test_student"
    check action.a == 0
    check action.b == 6
    check action.say == "a hunch"
    check sim.checkAct(0, action) == ""

  test "ingredient prefixes, indices and case variants all resolve":
    check resolveIngredient("Nightcap") == 0
    check resolveIngredient("nightcap") == 0
    check resolveIngredient("NIGHT") == 0
    check resolveIngredient("0") == 0
    check resolveIngredient("7") == 7
    check resolveIngredient("Rime") == 7
    check resolveIngredient("widows salt") == 3
    check resolveIngredient("wid") == 3
    ## Ambiguous and unknown both fail closed.
    check resolveIngredient("xyzzy") == -1
    check resolveIngredient("8") == -1
    check resolveIngredient("") == -1

  test "every free-text field is capped on rune boundaries":
    var sim = initSim(fixture(6))
    sim.drive()
    var payload = %*{
      "action": "pass",
      "a": "", "b": "", "signature": "", "artifact": "",
      "say": "é".repeat(400),
      "notes": "ü".repeat(900)
    }
    let action = parseReply(sim, 0, payload)
    check action.say.runeLen == MaxSayLen
    check action.notes.runeLen == MaxNotesLen
    check action.say.validateUtf8() == -1
    check action.notes.validateUtf8() == -1
    check cleanText("a".repeat(100), MaxActionLen).runeLen == MaxActionLen

  test "wrong-phase, unresolvable, malformed and unaffordable are invalid":
    var sim = initSim(fixture(7))
    sim.drive()
    check sim.phase == phLab
    ## A market action in the lab phase.
    expect CogchemistsError:
      discard parseReply(sim, 0, %*{"action": "publish", "a": "Nightcap",
        "signature": "R+G-B+"})
    ## An ingredient that does not resolve.
    expect CogchemistsError:
      discard parseReply(sim, 0, %*{"action": "transmute", "a": "Moonjuice"})
    ## No action at all.
    expect CogchemistsError:
      discard parseReply(sim, 0, %*{"say": "hello"})
    ## A malformed signature, in the phase where publish is legal.
    for seat in initiativeOrder(sim.round):
      sim.applyAct(seat, newAction("pass"), true)
    sim.drive()
    check sim.phase == phMarket
    expect CogchemistsError:
      discard parseReply(sim, 0, %*{"action": "publish", "a": "Nightcap",
        "signature": "R+G-"})
    expect CogchemistsError:
      discard parseReply(sim, 0, %*{"action": "buy", "artifact": "telescope"})
    ## Unaffordable: the schema reads it, and the RULES refuse it — which is
    ## what decideAll probes with before accepting a reply.
    sim.seats[0].coin = 0
    let broke = parseReply(sim, 0, %*{"action": "publish", "a": "Nightcap",
      "signature": "R+G-B+"})
    check sim.checkAct(0, broke) == "no_coin"

  test "trailing prose after the JSON object is tolerated":
    let text = "```json\n{\"action\":\"pass\",\"notes\":\"ok\"}\n```\n" &
      "I hope that helps!"
    let node = extractJsonObject(text)
    check node["action"].getStr() == "pass"
    expect CogchemistsError:
      discard extractJsonObject("I am afraid I cannot do that.")
