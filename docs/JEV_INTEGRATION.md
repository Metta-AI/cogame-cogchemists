# Jev as a Cogchemists player

`cogchemists.player.v2` lets a player register external action control. The
game sends the acting seat its ordinary private state and complete exact
legal move list for each simultaneous phase. The player returns a decision ID
and one move label. The game checks the phase and ID, maps the label to a
legal Action, resolves all seats in initiative order, and owns results and
replay. Prompt and assayer/quack scripted players remain on the same build.

`PLAYER_JEV=1` ranks exact legal labels through SystemOne inside the player
container. Direct `TYPESAFE_API_KEY` and the hosted inference sidecar are
player credentials. `PLAYER_PROMPT` can add player-side strategy guidance.
The complete legal menu has at most 175 candidate shapes under the rules, so
it fits SystemOne's 255-choice limit.

## Local evidence

Build with `coworld[auth]==0.1.43`, `--version 0.1.99`, and
`--compose compose.jev-local.yaml`. The normal prompt and assayer roster is
certified separately. The mixed smoke runs:

```bash
python3 tools/ci/smoke_jev.py /tmp/cogchemists-jev-smoke
```

The mock SystemOne smoke covers the standard and silent-academy variants,
plus a standard episode with two Jev seats in each simultaneous phase batch.
The three episodes accepted 24 Jev actions: lab forages and market passes,
with no scripted fallback. It checks the private state, complete legal menu,
direct and sidecar headers, results, and replayed moves.
The release-pinned Coworld build certified the unchanged prompt/assayer roster
with 10/10 transcript checks. Linux native tests passed all five suites in
debug and release. The ordinary Docker smoke completed with four players.
The static replay viewer at `http://127.0.0.1:39815/?replay=replay.json`
loaded the two-Jev replay; the round-one Jev forage event opened in the
timeline.
These decisions verify interface wiring, not Jev quality or provider cost.
No hosted resource changed.
