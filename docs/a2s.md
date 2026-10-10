# A2S

All of it, and the two parts deliberately missing. The challenge and the shared socket are in [exposure.md](exposure.md).

Every request the protocol defines (`A2S_INFO`, `A2S_PLAYER`, `A2S_RULES`, `A2S_SERVERQUERY_GETCHALLENGE`, `A2A_PING`) and every extra-data field.

## Field order is not bit order

**The extra-data fields must be written in the protocol's field order, not the numeric order of the bits**: port (`0x80`), server id (`0x10`), spectator pair (`0x40`), keywords (`0x20`), game id (`0x01`). A reader walks them in that sequence and has no way to detect a writer that chose a different one: it reads a port out of the middle of a string. The suite reads every one of them back.

## Absent is honest, invented is not

`steam_id`, `spectator_port` and `game_id` are 0 and absent unless an operator sets them. **There is no platform identity behind this family, and a fabricated one is a lie a client acts on**: a client reading a server id expects to be able to ask that platform about it.

## The game-specific block

The one game-specific block the protocol carries is gated on `a2s_app_id` falling in a closed published range, so it can never fire by accident. It sits **before the version string**, not in the extra data, and a client for one of those app ids reads it unconditionally, so emitting it for any other id shifts every following field and produces a response that parses into nonsense rather than one that visibly fails. The matching per-player pair in `A2S_PLAYER` is written whether or not a provider filled it in, for the same reason: an absent block is not an empty one, it is a truncated response.

## `folder` is the app slug

Unless an operator changed `a2s_game_folder` from `"dot"`. Why is in [design.md](design.md#the-app-slug-is-display-only-and-says-so-everywhere). This is a wire-visible choice: a tracker grouping servers by folder sees them regroup when it changes.

## Not here, on purpose

- **Split responses are never compressed.** The compressed form is bzip2, the engine ships none, and the flag is optional: a client that never sees it set never needs one.
- **The older engine branch's split header is not emitted.** It differs in layout and is told apart by nothing in the packet; every client of the last fifteen years reads the format this sends.
