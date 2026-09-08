# Seed assets

Images the demo chain files, kept in the repo so a reseed cannot lose them.

`fauci.jpg` was set by hand through the composer once and vanished with the
next chain reset — the bytes lived only in the archive's blob store, and the
archive serves a blob only while the chain still references it. Reported as
"fauci image is gone, in the map".

## Why the repo and not just the archive

A media item on chain must name a mirror on the realm's host allowlist
(`media.gno`, `defaultMediaHostsExact` / `defaultMediaHostSuffixes`) — a digest
alone is not a location, and the realm refuses one with
"a media item needs somewhere to find it". `.githubusercontent.com` is on that
list and this repository is public, so the file committed here is reachable at

    https://raw.githubusercontent.com/jaekwon/cryptocourt/main/scenarios/assets/fauci.jpg

which is the mirror the seed files. The archive still serves the bytes locally
at `/m/<sha256>` once the chain references them; the mirror is what makes the
item legal and what survives a chain that has never seen it.

| file | sha256 | dimensions | bytes | source |
|---|---|---|---|---|
| fauci.jpg | `756a9d89538b94c4368a33c1bf77d554114867d9135da9742df7b6e17c162ddc` | 960x1344 | 184593 | NIAID, via Wikimedia Commons, CC BY 2.0 |

The digest is the item's address: change the bytes and the seed line must change
with them, or the realm stores an address that describes something else.
