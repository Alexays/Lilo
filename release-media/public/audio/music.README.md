# Release announcement music

`music.ogg` is **Week 37 – Schmoovin** by **Abstraction / Tallbeard Studios**, from the creator’s Music Loop Bundle, version 20261003-01 (2026 Q3).

The creator dedicates the bundle to **CC0 1.0 Universal** and explicitly permits commercial use and modification. Attribution is optional, so no music-credit line is needed in the films. The bundled original notice remains in `music.LICENSE.txt`; `music.license.json` pins both files’ SHA-256 hashes and records the source. No endorsement by the musician is implied.

- Creator’s source and license statement: <https://tallbeard.itch.io/music-loop-bundle>
- CC0 deed: <https://creativecommons.org/publicdomain/zero/1.0/>
- CC0 legal code: <https://creativecommons.org/publicdomain/zero/1.0/legalcode>

The committed OGG is the original creator-provided track. Render preparation trims it, changes its gain and adds fades; it does not synthesize a replacement. CI reads the committed source and needs no music service or network request.

`make release-media-music` verifies the bundled file or restores it from the creator’s free archive, checking the pinned track hash. The fetcher uses the anonymous “No thanks, just take me to the downloads” endpoint, then extracts the single track and original license. It never submits payment information or uses an account. The full downloaded archive is held only in memory and discarded.

License verified on 2026-11-02. Sound quality and pacing still require listening review in the final film.
