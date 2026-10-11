// What the pages of the documentation do beyond being read: the list of pages on a phone, a button to
// copy each example, the outline that follows the page, and the diagrams.

import { isDark, onAppearanceChange, startAppearanceButtons } from './appearance.js'
import { makeCopyButton } from './copy.js'

const root = document.documentElement
startAppearanceButtons()

// The list of pages, behind a button where the screen is too narrow for it next to the page. While it
// is over the page, the page under it is out of the keyboard's reach.
const menu = document.querySelector('[data-docs-menu]')
if (menu) {
    const list = document.getElementById('docs-nav')
    const covered = document.querySelectorAll('.docs-main, .site-footer')
    const show = (isShowing) => {
        if (!isShowing && list.contains(document.activeElement)) menu.focus()
        root.classList.toggle('is-showing-contents', isShowing)
        menu.setAttribute('aria-expanded', String(isShowing))
        for (const element of covered) element.inert = isShowing
    }
    menu.addEventListener('click', () => show(!root.classList.contains('is-showing-contents')))
    document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') show(false)
    })
    // Coming back to the page, the list isn't still over it.
    addEventListener('pageshow', (event) => {
        if (event.persisted) show(false)
    })
}

for (const block of document.querySelectorAll('.code')) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'code-copy'
    button.textContent = 'Copy'
    button.setAttribute('aria-label', 'Copy this example')
    block.append(button)
    makeCopyButton(button, () => block.querySelector('code').textContent)
}

// The outline marks the section that is at the top of the window.
const outline = document.querySelector('[data-outline]')
if (outline) {
    const links = new Map([...outline.querySelectorAll('a')].map((link) => [decodeURIComponent(link.hash.slice(1)), link]))
    const headings = [...links.keys()].map((id) => document.getElementById(id)).filter(Boolean)
    const mark = () => {
        // The last heading that has passed under the header, or the first one above all of them. At the
        // foot of the page it is the last one, which may never get that far up.
        const atFoot = innerHeight + scrollY >= root.scrollHeight - 2
        const current = atFoot ? headings.at(-1) : (headings.findLast((heading) => heading.getBoundingClientRect().top < 120) ?? headings[0])
        for (const [id, link] of links) link.classList.toggle('is-current', id === current?.id)
    }
    let frame = null
    addEventListener(
        'scroll',
        () => {
            frame ??= requestAnimationFrame(() => {
                frame = null
                mark()
            })
        },
        { passive: true },
    )
    mark()
}

const diagrams = [...document.querySelectorAll('.mermaid')]
if (diagrams.length > 0) drawDiagrams(diagrams)

/** Draws the page's diagrams, in the colours of the appearance the page is shown in. */
async function drawDiagrams(diagrams) {
    for (const diagram of diagrams) diagram.dataset.source = diagram.textContent
    try {
        await new Promise((resolve, reject) => {
            const script = document.createElement('script')
            script.src = '/assets/vendor/mermaid.js'
            script.onload = resolve
            script.onerror = reject
            document.head.append(script)
        })
    } catch {
        // Without the script that draws them, the diagrams stay their own source.
        for (const diagram of diagrams) diagram.classList.add('has-failed')
        return
    }

    const draw = async () => {
        const dark = isDark()
        const colours = dark
            ? { fill: '#1e1f23', border: '#4a4b52', text: '#f5f5f7', line: '#8e8e93', group: '#18191c' }
            : { fill: '#f5f5f7', border: '#c7c7cc', text: '#1d1d1f', line: '#8e8e93', group: '#fbfbfd' }
        window.mermaid.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            // Flat boxes, as GitHub draws the same diagrams, instead of the shadowed ones that are the default.
            look: 'classic',
            // A diagram that can't be drawn stays its own source, and isn't replaced by a picture of an error.
            suppressErrorRendering: true,
            theme: 'base',
            fontFamily: getComputedStyle(document.body).fontFamily,
            themeVariables: {
                fontSize: '14px',
                primaryColor: colours.fill,
                primaryBorderColor: colours.border,
                primaryTextColor: colours.text,
                lineColor: colours.line,
                textColor: colours.text,
                clusterBkg: colours.group,
                clusterBorder: colours.border,
                edgeLabelBackground: dark ? '#111214' : '#ffffff',
            },
        })
        // One at a time, so that one that can't be drawn doesn't take the others with it.
        for (const diagram of diagrams) {
            diagram.removeAttribute('data-processed')
            diagram.classList.remove('has-failed')
            diagram.textContent = diagram.dataset.source
            try {
                await window.mermaid.run({ nodes: [diagram] })
            } catch {
                diagram.removeAttribute('data-processed')
                diagram.textContent = diagram.dataset.source
                diagram.classList.add('has-failed')
            }
        }
    }
    onAppearanceChange(draw)
    await draw()
}
