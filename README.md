This is the **server query** asset for TMC's **Dot** collection. A server answers "who is on you, what are you running, and is it worth joining" — over a protocol trackers already speak, and over one that can actually say what a game knows.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Two protocols, one answer

Both read from the same snapshot, so they can never disagree about how many people are on the server.

| | **DQP** (the dot query protocol) | **A2S** |
| --- | --- | --- |
| Default | on | off |
| Transport | UDP, and WebSocket when enabled | UDP only |
| Body | JSON | packed bytes, positional |
| Extensible | add a field | break every parser |
| Challenge | always, address-bound | since 2020 |
| Game state | a whole section | substrings in `keywords` |
| Conditional polling | yes (`if_rev`) | no |
| Reachable from a browser | yes | never |
| Existing tooling | none | twenty years of it |

That last row is the only reason A2S is here, and it is a good enough one. Every server-list site, chat bot and uptime monitor speaks A2S and nothing else — so **all of A2S is here**, every request and every extra-data field, not a subset.

## Installing

Copy `addons/dot_server_query/`, [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` and [`dot-server`](https://github.com/modcommunity/dot-server)'s `addons/dot_server/` into your project and enable dot-server-query in *Project → Project Settings → Plugins*.

[dot-stats](https://github.com/modcommunity/dot-stats) is optional and is never named in the source; the bridge to it is duck-typed.

## Five minutes

```gdscript
var host := DotQueryHost.new()
host.app_url = "your-app-url"   # the app's URL segment on the website
server.add_child(host)          # finds the server and plugs itself in
```

That is the whole integration. dot-server holds one hook, `attach_query_host`, and this fills it; a server with no host attached simply answers nothing on the query port.

## One socket, or two

The two protocols are told apart by their first four bytes — `FF FF FF FF` is A2S, `DQP1` is not — so both can answer on **one** UDP port. That matters because the game port is the only port a tracker will try.

```gdscript
config.query_enabled = true
config.a2s_enabled = true
config.query_port = 0      # 0 -> the A2S port, so one socket serves both
config.a2s_port = 0        # 0 -> the game port
```

Give them different ports and they bind separately. Give them the same one and DQP binds it and hands A2S the datagrams that are A2S's. Neither arrangement changes a byte of either protocol.

**A UDP game transport (ENet) already holds the game port**, so that bind fails and the log says exactly that. Set `query_port` to a free one — and know that most trackers will not look there.

## Why every query is challenged

UDP source addresses are forged trivially, and a query is a small request producing a large response: the exact shape of a DDoS amplifier. Send a 30-byte packet with a victim's address in the source field and an unprotected server mails the victim a kilobyte.

So an unchallenged request is answered with a cookie and nothing else, and that reply is **smaller than the request that provoked it**. The cookie is `HMAC(secret, address|port|bucket|width)`, bound to the address and port it was mailed to, so a forger never receives one and can never present one.

**Nothing is stored.** A challenge table is itself a memory-exhaustion target — ask for a million challenges from a million forged addresses and the server holds them all. This holds one 32-byte secret regardless. Same reasoning as a SYN cookie.

## What a query can ask for

Sections, by name, à la carte:

| | |
| --- | --- |
| `info` | identity, counts, addresses — what a server browser lists from |
| `players` | one row per player, governed by `query_player_detail` |
| `rules` | server variables a querier is allowed to see |
| `game` | whatever the game contributes through a `DotQueryProvider` |
| `teams` | sides and their sizes, when a team roster is present |
| `rotation` | what is playing, what is next, what else this server runs |
| `perf` | tick, frame time, memory, uptime |
| `build` | engine, server and platform versions |
| `stats` | declared statistics, their schema, and server-wide totals |
| `player_stats` | per-player statistics — off unless an operator configures it |

`info.connecting` is the field A2S has no room for, and it is the difference between "empty server" and "server nobody can finish joining".

## Polling is nearly free

Every response carries a revision that changes **only when something meaningful did**. A tracker sends the revision it holds and gets forty bytes back when nothing moved.

```json
{"sections": ["info", "players"], "if_rev": 41}
```

Uptime and the whole `perf` section are excluded from the hash it is derived from. They change every rebuild, and hashing them would mean the revision never once saved a byte.

## A browser can use it

With `query_websocket` on, the same protocol is served as plain JSON text frames:

```js
const ws = new WebSocket("ws://example.com:27018");
ws.onopen = () => ws.send(JSON.stringify({ sections: ["info", "players"] }));
ws.onmessage = e => console.log(JSON.parse(e.data));
```

A web page cannot open a UDP socket, so it can never speak A2S at any price — and "click a link and play" needs a server list for the link to come from.

## Contributing your game's state

A2S has four fixed questions. Anything that does not fit them — a round number, per-team scores, the next map, a lobby's ready count — has historically been smuggled into the keywords string as `r3,t1:8,t2:5` and hoped for.

```gdscript
class ArenaQuery extends DotQueryProvider:
    func _provider_name() -> String:
        return "arena"

    func _contribute(snapshot: DotQuerySnapshot) -> void:
        snapshot.info["bots"] = match_state.bot_count()
        snapshot.contribute_game({
            "phase": match_state.phase_name(),
            "round": match_state.round_number,
            "time_left": match_state.seconds_remaining(),
        })

DotRegistry.get_service(&"dot_query_source").add_provider(ArenaQuery.new())
```

**The bot count is the one that proves the point.** Nothing in a server framework can know it — a bot is a game concept and the server never sees one connect — so it reaches A2S's bot byte, DQP's `info.bots` and the backbone stats report only through a provider.

## Statistics, optionally

`DotQueryStats` bridges [dot-stats](https://github.com/modcommunity/dot-stats) without naming it. Three kinds of question: what this box has done since it booted, the published stats totalled across everyone on it, and one row per player.

The first two are on by default and identify nobody. **The third is off, and a boolean is not enough to turn it on**: a game chooses its own key for a stats player and nothing records which, so publishing rows needs `player_key_format` (or a resolver) as well. The key itself is never published — rows carry the display name and userid the player list already carries.

## The wire spec

[`addons/dot_server_query/PROTOCOL.md`](addons/dot_server_query/PROTOCOL.md) is enough to write a client in any language, and ends with one in about thirty lines of Python. [dot-browser](https://github.com/modcommunity/dot-browser) is the client half for a Godot project.

## Testing

```bash
godot --headless --path . res://examples/query_selftest.tscn
```

164 checks. Both protocols run end to end without a socket — `handle_datagram` takes a datagram and returns the datagrams to send back — covering challenge binding, fragmentation, gzip, conditional polling, reflection refusal, rate limiting, and every A2S response read back field by field. The listeners still bind for real as well, so the shared-socket path is exercised rather than assumed.

## Licence

MIT. See [LICENSE](LICENSE).
