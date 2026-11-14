Lets a game server answer "who is on you, what are you running, and is it worth joining". It speaks two protocols from one snapshot, so they never disagree about the player count.

| | **DQP** (the dot query protocol) | **A2S** |
| --- | --- | --- |
| Default | on | off |
| Transport | UDP, and WebSocket when enabled | UDP only |
| Body | JSON | packed bytes |
| Extensible | add a field | breaks parsers |
| Game state | a whole section | substrings in `keywords` |
| Conditional polling | yes (`if_rev`) | no |
| Reachable from a browser | yes | no |
| Existing tooling | none | twenty years of it |

Server-list sites, chat bots and uptime monitors speak A2S, so all of A2S is implemented, every request and every extra-data field.

## Install

1. Get [Godot 4.7](https://godotengine.org/download).
2. Either use [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which clones every project and links the addons, or copy `addons/dot_server_query/`, [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` and [dot-server](https://github.com/modcommunity/dot-server)'s `addons/dot_server/` into your project and enable dot-server-query in *Project > Project Settings > Plugins*.

[dot-stats](https://github.com/modcommunity/dot-stats) is optional.

## Use

```gdscript
var host := DotQueryHost.new()
host.app_url = "your-app-url"   # the app's URL segment on the website
server.add_child(host)          # finds the server and plugs itself in
```

A server with no host attached answers nothing on the query port.

## One socket, or two

The protocols are told apart by their first four bytes (`FF FF FF FF` is A2S, `DQP1` is DQP), so both can answer on one UDP port. The game port is the only port a tracker will try.

```gdscript
config.query_enabled = true
config.a2s_enabled = true
config.query_port = 0      # 0 = the A2S port, so one socket serves both
config.a2s_port = 0        # 0 = the game port
```

Different ports bind separately. On the game port with dot-server's default transport (`DotTransportDual`) both protocols share the transport's UDP socket and nothing binds a second one. If another process or a plain ENet transport holds the port, the bind fails and the log says so. Then set `query_port` to a free port, though most trackers will not look there.

## Every query is challenged

UDP source addresses are easy to forge, and a query is a small request with a large reply, which is how amplification attacks work. An unchallenged request gets a cookie smaller than the request. The cookie is an HMAC of the address, port and time, so a forger never receives one. The server stores nothing per request, only one 32-byte secret.

## What a query can ask for

| Section | Content |
| --- | --- |
| `info` | Identity, counts, addresses. `info.connecting` shows players still joining. |
| `players` | One row per player, governed by `query_player_detail`. |
| `rules` | Server variables a querier may see. |
| `game` | Whatever the game contributes through a `DotQueryProvider`. |
| `teams` | Sides and their sizes. |
| `rotation` | What is playing, what is next, what else this server runs. |
| `perf` | Tick, frame time, memory, uptime. |
| `build` | Engine, server and platform versions. |
| `stats` | Declared statistics, their schema and server-wide totals. |
| `player_stats` | Per-player statistics. Off unless an operator configures it. |

Every response carries a revision that changes only when something meaningful did. Send the one you hold and get a few bytes back when nothing moved:

```json
{"sections": ["info", "players"], "if_rev": 41}
```

## From a browser

With `query_websocket` on, the same protocol is served as JSON text frames:

```js
const ws = new WebSocket("ws://example.com:27018");
ws.onopen = () => ws.send(JSON.stringify({ sections: ["info", "players"] }));
ws.onmessage = e => console.log(JSON.parse(e.data));
```

## Adding your game's state

```gdscript
class FcQuery extends DotQueryProvider:
    func _provider_name() -> String:
        return "fc"

    func _contribute(snapshot: DotQuerySnapshot) -> void:
        snapshot.info["bots"] = match_state.bot_count()
        snapshot.contribute_game({
            "phase": match_state.phase_name(),
            "round": match_state.round_number,
            "time_left": match_state.seconds_remaining(),
        })

DotRegistry.get_service(&"dot_query_source").add_provider(FcQuery.new())
```

Only a provider can report the bot count, because the server never sees a bot connect. The map shown in `info.map` is dot-server's `DotGameManager.reported_map()`: the map the game reported with `set_current_map`, or the game's display name. Reporting a map drops the cached snapshot.

## Statistics

`DotQueryStats` bridges dot-stats without depending on it.

| Kind | Default |
| --- | --- |
| What this server has done since it booted | On, identifies nobody. |
| Published stats totalled across everyone | On, identifies nobody. |
| One row per player | Off. Also needs `player_key_format` (or a resolver). Rows carry the display name and userid only, never the stats key. |

## Protocol

[addons/dot_server_query/PROTOCOL.md](addons/dot_server_query/PROTOCOL.md) is enough to write a client in any language and ends with one in about thirty lines of Python. [dot-browser](https://github.com/modcommunity/dot-browser) is the client for a Godot project.

## Testing

Import the project once, then run `examples/query_selftest.tscn` headless with Godot. It runs both protocols without a socket and also binds the listeners for real.

## Status and licence

Part of the TMC **dot-\*** family of Godot addons. Written with Claude Code and maintained by `gamemann`. Every addon has headless tests, but little of this has been played by real users yet, so expect rough edges and please [open an issue](https://github.com/modcommunity/dot-server-query/issues) when you hit one.

MIT licence, see [LICENSE](LICENSE). The only closed part of the TMC platform is the web back end; you can use your own instead of TMC's.
