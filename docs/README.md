# dot-server-query docs

| File | What |
| --- | --- |
| [design.md](design.md) | why it is its own addon, the one hook in dot-server, the boot handshake, sections and the revision, `info.signon`, the app slug, the dot-stats bridge, what is not here |
| [exposure.md](exposure.md) | one socket or two, sharing ENet's port, the challenge, the bounded limiter, the snapshot cache, what A2S publishes |
| [a2s.md](a2s.md) | A2S field order, absent fields, the game-specific block, `folder`, what is not emitted |
| [history.md](history.md) | the bugs, and how each looked |

The wire spec, enough to write a client in any language, is [addons/dot_server_query/PROTOCOL.md](../addons/dot_server_query/PROTOCOL.md).
