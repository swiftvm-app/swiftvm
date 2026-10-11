// The night sky behind the landing page's hero: three tiles of stars that repeat at different sizes, so
// that no pattern shows. They are drawn from a seed, and so come out the same in every build.

/** A small random number generator (mulberry32) that gives the same numbers for the same seed. */
function random(seed) {
    let state = seed >>> 0
    return () => {
        state = (state + 0x6d2b79f5) >>> 0
        let value = Math.imul(state ^ (state >>> 15), 1 | state)
        value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value
        return ((value ^ (value >>> 14)) >>> 0) / 4294967296
    }
}

const round = (value) => Math.round(value * 100) / 100

/**
 * One tile of stars as an SVG image.
 *
 * @param size The side of the tile, in pixels.
 * @param count How many stars it has.
 * @param radius The smallest and the largest star.
 * @param opacity The faintest and the brightest star.
 * @param glow Whether each star has a halo, as the near ones do.
 */
export function starTile({ seed, size, count, radius, opacity, glow = false }) {
    const next = random(seed)
    const between = ([low, high]) => low + next() * (high - low)
    const stars = []
    for (let index = 0; index < count; index++) {
        const r = between(radius)
        // Away from the edges, where a star would be cut in two.
        const x = round(r * 4 + next() * (size - r * 8))
        const y = round(r * 4 + next() * (size - r * 8))
        const alpha = round(between(opacity))
        // One star in four is a little blue, as on the wallpaper the hero is made after.
        const fill = next() < 0.25 ? '#bcd4ff' : '#fff'
        if (glow) {
            stars.push(`<circle cx="${x}" cy="${y}" r="${round(r * 2.4)}" fill="${fill}" opacity="${round(alpha * 0.1)}"/>`)
        }
        stars.push(`<circle cx="${x}" cy="${y}" r="${round(r)}" fill="${fill}" opacity="${alpha}"/>`)
    }
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">${stars.join('')}</svg>\n`
}

/** The tiles the landing page's stylesheet asks for, by file name. Their sizes are in home.css too. */
export function starTiles() {
    return {
        'stars-far.svg': starTile({ seed: 27, size: 420, count: 210, radius: [0.4, 0.75], opacity: [0.35, 0.9] }),
        'stars-mid.svg': starTile({ seed: 4, size: 610, count: 120, radius: [0.7, 1.15], opacity: [0.55, 1] }),
        'stars-near.svg': starTile({ seed: 11, size: 890, count: 34, radius: [1.1, 1.8], opacity: [0.8, 1], glow: true }),
    }
}
