## Cogchemists player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default alchemy strategy in words), then idles until the final frame.
## All of the actual decision making happens inside the game server, which
## sends this seat's prompt to Claude once per phase.
##
## PLAYER_SCRIPTED=assayer (or 1) registers the seat as the built-in
## competent scientist instead; PLAYER_SCRIPTED=quack as the reckless
## careerist. The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <cogchemists-image> --name my-cogchemists \
##     --run /bin/cogchemists-player --secret-env PLAYER_PROMPT="<strategy>"

import
  std/[json, options, os, strutils, unicode],
  whisky

const
  MaxPromptLen = 4000
  DefaultPrompt = """
Be the alchemist who knows. In the LAB, test the pair of cards that splits
your candidate set the most: a coloured result is worth far more than MUD,
so prefer pairs your grid says could go either way. Pay the student while
you have coin to spare; drink it yourself only when no consistent chemistry
makes that pair negative. In the MARKET, never publish an ingredient your
deduction grid has not SOLVED unless the last round is upon you and you are
behind - a false seal costs six reputation at the exhibition and four more
if someone burns it. Attack a rival's seal only with a reagent whose
demonstration MUST contradict their claim; a failed attack costs you two
reputation and makes the fraud stronger. Remember that everything you sell
or demonstrate is a free gift of information to your rivals, and that a
solved ingredient nobody has claimed is the best coin in the game.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  ## Rune boundary, not byte: a byte cut through a multi-byte character
  ## would put invalid UTF-8 into the game's log and the replay.
  if prompt.runeLen > MaxPromptLen:
    prompt = prompt.runeSubStr(0, MaxPromptLen)
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "cogchemists player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "cogchemists player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky RAISES on a close frame or a truncated read (only a timeout
  ## returns none) and mummy's send only queues, so the game's quit(0) can
  ## outrun the flushed final frame. A dead socket is a normal end of an
  ## episode, not a player failure: exit 0.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "cogchemists player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "cogchemists player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first
          ## send raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "cogchemists player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "cogchemists player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "cogchemists player: socket closed (", error.msg, "); exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
