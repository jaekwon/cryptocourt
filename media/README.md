# media/

Images the chain points at, hosted here because the realm will only store a
mirror on a host the browser will also load — `media.gno`'s allowlist and the
`img-src` in `deploy/nginx.conf` are the same list, and `.githubusercontent.com`
is on it. Nothing in this directory is served by `deploy.sh`; it ships only
`index.html`, `chat.js` and `media.js`. GitHub serves these.

LINK THEM BY COMMIT SHA, NOT BY BRANCH:

    https://raw.githubusercontent.com/jaekwon/cryptocourt/<sha>/media/<file>

A branch name in the URL is a moving target — rename or delete the branch and
every claim and folder pointing at it loses its picture, on a chain that cannot
be edited to follow. A commit sha is permanent.

## fauci.jpg

Anthony S. Fauci, M.D., Director of NIAID — the agency's own 2020 portrait.

  source   https://commons.wikimedia.org/wiki/File:Anthony_S._Fauci_(2020).jpg
  origin   NIAID, https://www.flickr.com/photos/niaid/50719588208/
  licence  Public domain (a work of the United States federal government)
  changes  resized to 480x640; not cropped or retouched

PUBLIC DOMAIN ON PURPOSE, and it took three tries. NIAID's own Flickr stream is
CC BY 2.0, and the obvious portrait there carries that licence — which requires
attribution wherever the image appears. A folder's picture on this site is drawn
with an empty `alt` and no caption, on a map node 116 units wide: there is
nowhere for a credit line to go, so a licence that demands one is the wrong
licence for this slot rather than a formality to wave through. The White House
photographs are public domain but show him masked, mid-briefing, beside other
people. This one is both: a portrait, and free of conditions this page cannot
meet.
