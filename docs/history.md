# History

Bugs found by running, not by reading. All parsed clean; each is easy to reintroduce.

- **One flag bit with two meanings.** `FLAG_GZIP` meant "I accept gzip" on a request and "this is gzipped" on a response, on the reasoning that a request is never compressed so the bit was free. It made the header un-parseable without already knowing the direction: the parser reads the header to find that out, so it tried to gunzip a plaintext request body and failed. Every query was silently dropped. `FLAG_ACCEPT_GZIP` is its own bit now.
- **A fragment is not independently decodable.** `parse()` gunzipped and JSON-parsed whatever payload it was handed, so reading a fragment's header (exactly what reassembly does first) logged two engine errors on a completely normal path. Nothing failed; it just looked broken in every log it appeared in.
- **The A2S `folder` changed in the extraction from dot-server**, from the configured string to the app slug, and an assertion inherited from dot-server's example failed. Intended, but wire-visible: see [a2s.md](a2s.md#folder-is-the-app-slug).
- **The per-address rate limiter grew without bound under a spoofed flood**: dot-core's `DotRateLimiter` never evicted a key that had sent one packet. Fixed by `DotQueryLimiter`; see [exposure.md](exposure.md#the-rate-limiter-is-bounded-too).
