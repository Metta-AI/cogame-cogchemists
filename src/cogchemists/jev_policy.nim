## Jev ranks Cogchemists' complete legal move labels in the player.

import std/[json, os, strutils, times]
import curly

var lastCall: float

proc chooseAction*(observation: JsonNode, guidance: string): JsonNode =
  var criteria = newJObject()
  for option in observation["legal"]:
    let label = option.getStr()
    criteria[label] = %label
  if criteria.len == 0:
    raise newException(ValueError, "Jev received no legal moves")
  if criteria.len > 255:
    raise newException(ValueError, "Cogchemists legal menu exceeds SystemOne")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint, model, key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Cogchemists Jev has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Cogchemists. Four alchemists race to earn " &
      "reputation by experiments, sales, publication, and debunking. " &
      "Choose one exact legal move using only your private laboratory view. " &
      guidance & "\nYour seat observation:\n" & $observation,
    "questions": {"move": {
      "type": "choice", "instructions": "Choose one exact legal move label.",
      "criteria": criteria
    }}
  }
  let elapsed = epochTime() - lastCall
  if lastCall > 0 and elapsed < 2.1:
    sleep(((2.1 - elapsed) * 1000).int)
  lastCall = epochTime()
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 18)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["move"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected: string
  for label, node in probabilities.pairs:
    if not criteria.hasKey(label):
      raise newException(ValueError, "Jev returned an unknown move")
    let probability = node.getFloat()
    if probability < 0 or probability > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += probability
    if probability > best:
      best = probability
      selected = label
  if abs(total - 1) > criteria.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Cogchemists Jev: move ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  %*{"type": "action", "move": selected}
