import std/[json, strutils], chem

export chem

type
  CogchemistsError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int          ## rounds of lab-then-market in the episode
    talk*: bool           ## seats may post one short seminar remark a phase
    artifacts*: bool      ## the mortar and the press are on sale
    episodeTimeoutSeconds*: int ## assumed platform kill time when env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    minBatchSpacingMs*: int ## wall-clock floor between LLM batch starts
    shutdownGraceSeconds*: int ## keep /healthz + /global alive after artifacts
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Phase* = enum
    phLab = "lab"
    phMarket = "market"
    phDone = "done"

  SealStatus* = enum
    sealStanding = "standing"
    sealBurned = "burned"

  Seal* = object
    ingredient*: int
    claim*: int            ## the claimed signature index
    author*: int
    roundPublished*: int
    endorsers*: seq[int]
    status*: SealStatus
    vindications*: int     ## demonstrations it survived
    burnedBy*: int
    roundBurned*: int

  SeatState* = object
    coin*: int
    reputation*: int
    hand*: seq[int]           ## a multiset of ingredient indexes
    mortar*: bool
    press*: bool
    privateFacts*: seq[Fact]  ## this seat's own mixFull results
    notes*: string
    say*: string              ## this phase's remark
    heard*: string            ## last phase's remark
    published*: seq[int]      ## ingredients this seat pinned a seal on
    endorsed*: seq[int]       ## ingredients this seat co-signed

  SeatSnapshot* = object
    coin*, reputation*, handCount*: int
    mortar*, press*: bool
    score*: float

  Verdict* = object
    ingredient*, claim*, author*: int
    endorsers*: seq[int]
    correct*: bool

  EventKind* = enum
    evStart = "start"
    evRound = "round"
    evPhase = "phase"
    evAct = "act"
    evExhibition = "exhibition"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    round*: int            ## round/phase/act/exhibition: the round; end: rounds played
    phase*: Phase          ## phase/act only
    seat*: int             ## act only; -1 otherwise
    action*: string        ## act: the verb played
    a*, b*: int            ## act: ingredient indexes, -1 when unused
    signature*: int        ## act: claimed signature, -1 when unused
    artifact*: string      ## act: "mortar" | "press"
    potion*: Potion        ## act: the outcome potion, private ones included
    secret*: bool          ## act: rivals saw only the sign class, or nothing
    draws*: seq[int]       ## act/start: ingredients drawn
    discarded*: seq[int]   ## act: draws that overflowed the hand cap
    outcome*: string       ## act: ok|hit|miss|poisoned|glowed|burned|survived|rejected:<reason>
    coinDelta*: int
    repDelta*: int
    target*: int           ## act: the seal's author on endorse/debunk; -1 otherwise
    scripted*: bool
    say*: string
    text*: string          ## act: the seat's notes after this reply; end: reason
    demand*: Potion        ## round: the adventurer's demand
    initiative*: seq[int]  ## round: the resolution order
    royalties*: seq[int]   ## round: coin paid to each seat at the open
    seats*: seq[SeatSnapshot] ## round: public snapshots
    chemistry*: seq[int]   ## start/exhibition: the true bijection
    hands*: seq[seq[int]]  ## start: the four seeded opening hands
    verdicts*: seq[Verdict] ## exhibition
    repDeltas*: seq[int]   ## exhibition

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 6,
    talk: true,
    artifacts: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 250,
    minBatchSpacingMs: 10_000,
    shutdownGraceSeconds: 20,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 20
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(CogchemistsError, "config must be a JSON object")
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
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("talk"):
    config.talk = node["talk"].getBool()
  if node.hasKey("artifacts"):
    config.artifacts = node["artifacts"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("minBatchSpacingMs"):
    config.minBatchSpacingMs = node["minBatchSpacingMs"].getInt()
  if node.hasKey("shutdownGraceSeconds"):
    config.shutdownGraceSeconds = node["shutdownGraceSeconds"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.rounds < 3:
    raise newException(CogchemistsError, "rounds must be at least 3")
