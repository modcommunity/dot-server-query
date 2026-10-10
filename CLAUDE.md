# dot-server-query

The server's side of a server query: the dot query protocol (DQP) and the whole of A2S, answered from one snapshot, on one socket or two.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to query. The reasoning is in [docs/](docs/README.md); the wire spec is [PROTOCOL.md](addons/dot_server_query/PROTOCOL.md).

**The distributable is `addons/dot_server_query/`.** It requires dot-core and dot-server, and optionally bridges dot-stats, which is discovered at runtime and named nowhere in the source. The suite wants all three linked (`.gitignore`): linking the real dot-stats is what checks the duck-typed bridge against the thing it describes rather than a mock.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | the dot-server hook, `DotQueryHost`, `DotQuerySource`, snapshot sections, `info.*` fields, `DotQueryStats` |
| [docs/exposure.md](docs/exposure.md) | the listeners, port sharing, `DotQueryChallenge`, `DotQueryLimiter`, the cache |
| [docs/a2s.md](docs/a2s.md) | `DotA2SServer` |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |
| [PROTOCOL.md](addons/dot_server_query/PROTOCOL.md) | changing anything on the wire |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_server_query/PROTOCOL.md` | the wire spec; enough to write a client in any language |
| `addons/dot_server_query/host/` | `DotQueryHost`: finds a server, fills its hook, owns the listeners, registers the two commands |
| `addons/dot_server_query/core/` | `DotQueryChallenge` (stateless address-bound cookies), `DotQueryLimiter`, `DotQuerySnapshot`, `DotQueryProvider` (where a game contributes state) |
| `addons/dot_server_query/source/` | `DotQuerySource`: builds and caches the snapshot; holds the providers |
| `addons/dot_server_query/dqp/` | `DotQueryProtocol` (header, flags, fragments, gzip), `DotQueryServer` (UDP, and WebSocket for browsers) |
| `addons/dot_server_query/a2s/` | `DotA2SServer`: A2S, all of it; off by default |
| `addons/dot_server_query/stats/` | `DotQueryStats`: the dot-stats bridge; names no `DotStats*` identifier |
| `examples/query_selftest.tscn` | the suite; `-- --serve` runs it as a real server instead |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/query_selftest.tscn`. Exits non-zero on failure. The last section boots a dual-stack server and asks A2S, and joins over ENet, on one real UDP port.
- Both protocols are driven without a socket: `handle_datagram` takes a datagram and returns the datagrams to send, so DQP and A2S run in process (and on a machine where binding is refused). The listeners still bind for real in the example, so the shared-socket path is exercised rather than assumed.
- **A change here means re-running dot-server's `examples/dedicated_server.tscn`, game-arena's and game-g2gfast's `examples/dedicated.tscn`.** Arena asks its own server over a real UDP socket through dot-browser; g2gfast asserts what its module contributes.

## Rules that bite

**The dependency**

- dot-server names nothing here: one hook, `attach_query_host(host: Object)`, and every query field on `DotServer` is `Object` reached by `.call`. Naming a class from here in dot-server would make this addon mandatory. [design](docs/design.md#the-direction-of-the-dependency-is-the-whole-design)
- The query settings (`query_*`, `a2s_*`, `sv_query`, `sv_a2s`, `sv_query_players`) stay on `DotServerConfig` so operators' config files keep working; settings that exist only here are node exports. [design](docs/design.md#the-direction-of-the-dependency-is-the-whole-design)
- `DotQueryHost._ready` waits for `dot_server` on the registry path, because a host beside a server is ready before the server registers. Both boot orders are in the suite. [design](docs/design.md#the-boot-handshake-in-both-directions)
- dot-team (`dot_team_roster`) and dot-stats are duck-typed; never name their classes. [design](docs/design.md#sections-and-the-two-rules-about-the-revision)

**The snapshot**

- Build every section on every rebuild; the revision is a hash of the content, and conditional building makes it lie. [design](docs/design.md#sections-and-the-two-rules-about-the-revision)
- `perf`, `info.uptime` and per-player `duration`/`ping` are out of the hash (`VOLATILE_SECTIONS`), or `if_rev` never saves a byte. [design](docs/design.md#sections-and-the-two-rules-about-the-revision)
- `info.signon` belongs in `info`, the section every listing row fetches, so a browser knows before connecting. [design](docs/design.md#infosignon-is-the-field-a-browser-needs-before-it-connects)
- `info.app` (and A2S `folder`) is display-only; nothing that must be sure of a server's app may read it. [design](docs/design.md#the-app-slug-is-display-only-and-says-so-everywhere)
- Per-player stats need `player_key_format` or a resolver as well as `publish_players`; the stats key is never published; only `publish` stats go out. [design](docs/design.md#the-dot-stats-bridge-and-the-join-that-cannot-be-guessed)

**Exposure**

- An unchallenged request gets a cookie and nothing else, smaller than the request; cookies are stateless HMACs bound to address and port; the previous bucket is accepted; a response on the listening socket is never answered. [exposure](docs/exposure.md#the-challenge-is-the-reason-this-is-safe-to-expose)
- WebSocket has no challenge on purpose: the TCP handshake already proved the address. [exposure](docs/exposure.md#the-challenge-is-the-reason-this-is-safe-to-expose)
- The per-address limiter must stay bounded (`DotQueryLimiter`, `max_tracked`); its key is an unproved address. [exposure](docs/exposure.md#the-rate-limiter-is-bounded-too)
- `query_cache_sec` is a security control: never rebuild a snapshot per packet. [exposure](docs/exposure.md#the-snapshot-cache-is-a-security-control-not-an-optimisation)
- On ENet's port, register through `share_udp_port`, never bind; the claim test runs on every game packet, so keep it cheap. [exposure](docs/exposure.md#one-socket-or-two-and-why-one-is-the-point)

**Wire**

- A request flag and a response flag never share a bit (`FLAG_ACCEPT_GZIP`); a fragment is not decodable on its own. [history](docs/history.md)
- A2S extra-data fields go in field order, not bit order. [a2s](docs/a2s.md#field-order-is-not-bit-order)
- Never fabricate a platform id; the game-specific block only for `a2s_app_id` in the published range, and its per-player pair always written when it is on. [a2s](docs/a2s.md)
- `query_player_detail` governs A2S too; A2S publishes a roster to anyone. [exposure](docs/exposure.md#what-a2s-publishes)

Deliberately not here: a query client (dot-browser, a second implementation on purpose), delta responses, a master-server heartbeat, signing on by default. [design](docs/design.md#deliberately-not-here)
