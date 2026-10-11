// The HTML around what each page says: the document, the header and footer, and the frame of a page of
// the documentation.

import { escapeHTML } from '../src/assets/panel.js'
import { site } from './config.mjs'

/**
 * What has to be so before anything is drawn: that scripts run here, which the stylesheets ask about as
 * `.js`, and the appearance the visitor chose. See src/assets/appearance.js.
 */
const beforeDrawing = `<script>document.documentElement.classList.add("js");try{const a=localStorage.getItem("appearance");if(a)document.documentElement.dataset.theme=a}catch{}</script>`

/**
 * The button that turns the page light or dark: the sun by day, the moon by night. It stays hidden
 * until the script that makes it work is there.
 */
export function appearanceButton(className = '') {
    return `<button type="button" class="appearance${className ? ` ${className}` : ''}" data-appearance hidden aria-label="Switch appearance">
    <svg class="appearance-sun" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="3.1" fill="currentColor"/><path d="M8 1.2v1.7M8 13.1v1.7M1.2 8h1.7M13.1 8h1.7M3.2 3.2l1.2 1.2M11.6 11.6l1.2 1.2M12.8 3.2l-1.2 1.2M4.4 11.6l-1.2 1.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
    <svg class="appearance-moon" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="M13.9 9.9A6.1 6.1 0 0 1 6.1 2.1a.5.5 0 0 0-.66-.6 6.6 6.6 0 1 0 9.06 9.06.5.5 0 0 0-.6-.66z" fill="currentColor"/></svg>
</button>`
}

const stylesheet = (name) => `<link rel="stylesheet" href="/assets/${name}.css">`
const moduleScript = (name) => `<script type="module" src="/assets/${name}.js"></script>`

/**
 * A whole document.
 *
 * @param title The page's own title. The landing page has none and is titled after the site.
 * @param path Where the page is on the site, for its canonical address.
 * @param styles The stylesheets it needs besides the one every page has, by name.
 * @param scripts The scripts it needs, by name.
 * @param themeColor The colours a phone's browser draws around the page, by day and by night.
 */
export function layout({ title, description, path, body, styles = [], scripts = [], themeColor }) {
    const fullTitle = title ? `${title} · ${site.name}` : `${site.name}: ${site.tagline}`
    const address = site.url + path
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHTML(fullTitle)}</title>
<meta name="description" content="${escapeHTML(description)}">
<link rel="canonical" href="${address}">
<meta property="og:site_name" content="${site.name}">
<meta property="og:type" content="website">
<meta property="og:title" content="${escapeHTML(title ?? `${site.name}: ${site.tagline}`)}">
<meta property="og:description" content="${escapeHTML(description)}">
<meta property="og:url" content="${address}">
<meta property="og:image" content="${site.url}/og.jpg">
<meta name="twitter:card" content="summary_large_image">${
        themeColor
            ? `\n<meta name="theme-color" media="(prefers-color-scheme: light)" content="${themeColor.light}">\n<meta name="theme-color" media="(prefers-color-scheme: dark)" content="${themeColor.dark}">`
            : ''
    }
<link rel="icon" href="/favicon.png" sizes="64x64" type="image/png">
<link rel="icon" href="/assets/logo.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
${beforeDrawing}
${['base', ...styles].map(stylesheet).join('\n')}
${scripts.map(moduleScript).join('\n')}
</head>
<body>
${body}
${footer()}
</body>
</html>
`
}

/** The header of every page but the landing page, whose hero has a menu bar instead. */
function header({ isDocs = false } = {}) {
    return `${isDocs ? '<a class="skip-link" href="#content">Skip to the page</a>\n' : ''}<header class="site-header">
    <div class="container">
        <a class="site-brand" href="/"><img src="/assets/logo.svg" alt="" width="24" height="24">${site.name}</a>
        <nav class="site-nav" aria-label="Site">
            <a href="/docs/"${isDocs ? ' aria-current="true"' : ''}>Docs</a>
            <a href="${site.repository}">GitHub</a>
        </nav>
        ${isDocs ? '<button type="button" class="docs-menu" data-docs-menu aria-expanded="false" aria-controls="docs-nav">Contents</button>' : ''}
        ${appearanceButton()}
        <a class="button button-primary button-small" href="${site.download}">Download</a>
    </div>
</header>`
}

function footer() {
    return `<footer class="site-footer">
    <div class="container">
        <p>${site.name} is open source, released under the Apache-2.0 license.</p>
        <nav aria-label="More">
            <a href="/docs/">Docs</a>
            <a href="${site.repository}">GitHub</a>
            <a href="${site.repository}/releases">Releases</a>
            <a href="${site.repository}/issues">Issues</a>
        </nav>
    </div>
</footer>`
}

// MARK: Documentation

/** The list of every page, at the side of each. */
function navigation(sections, current) {
    const link = (page) =>
        `<li><a href="${page.url}"${page === current ? ' aria-current="page"' : ''}>${escapeHTML(page.label)}</a></li>`
    const groups = sections.map(
        (section) => `<div class="docs-nav-section">
            <h2>${escapeHTML(section.title)}</h2>
            <ul>${section.pages.map(link).join('')}</ul>
        </div>`,
    )
    return `<aside class="docs-nav" id="docs-nav">
        <nav aria-label="Documentation">
        ${groups.join('\n        ')}
        </nav>
    </aside>`
}

/** What keeps the outline's place on a page that is too short to have one. */
const noOutline = '<div class="docs-outline"></div>'

/** The sections of the page that is open, at its other side. */
function outline(headings) {
    const entries = headings.filter((heading) => heading.level === 2 || heading.level === 3)
    if (entries.length < 2) return noOutline
    const items = entries.map(
        (heading) => `<li class="level-${heading.level}"><a href="#${encodeURIComponent(heading.id)}">${escapeHTML(heading.text)}</a></li>`,
    )
    return `<aside class="docs-outline">
        <nav aria-label="On this page" data-outline>
            <h2>On this page</h2>
            <ul>${items.join('')}</ul>
        </nav>
    </aside>`
}

function docsFrame({ sections, current, main, side = noOutline }) {
    return `${header({ isDocs: true })}
<div class="docs container">
    ${navigation(sections, current)}
    <main class="docs-main" id="content">
${main}
    </main>
    ${side}
</div>`
}

/**
 * A page of the documentation.
 *
 * @param page The page, from `loadDocs`.
 * @param html What it says, from `renderPage`.
 * @param ordered Every page in the order of the navigation, for the links to the ones before and after.
 */
export function docsPage({ page, html, sections, ordered }) {
    const index = ordered.indexOf(page)
    const neighbour = (other, direction) =>
        other
            ? `<a class="docs-pager-${direction}" href="${other.url}"><span>${direction === 'previous' ? 'Previous' : 'Next'}</span>${escapeHTML(other.title)}</a>`
            : '<span></span>'
    const main = `        <article class="prose">
${html}        </article>
        <nav class="docs-pager" aria-label="Pages">
            ${neighbour(ordered[index - 1], 'previous')}
            ${neighbour(ordered[index + 1], 'next')}
        </nav>
        <p class="docs-edit"><a href="${site.repository}/edit/${site.branch}/docs/${encodeURI(page.source)}">Edit this page on GitHub</a></p>`
    return layout({
        title: page.title,
        description: page.lead ?? `${page.title}, in the documentation of ${site.name}.`,
        path: page.url,
        body: docsFrame({ sections, current: page, main, side: outline(page.headings) }),
        styles: ['docs'],
        scripts: ['docs'],
    })
}

/** The first page of the documentation: every page, by section, with what it is about. */
export function docsIndex({ sections }) {
    // A page that doesn't open with a sentence about itself is described by its sections.
    const about = (page) =>
        page.lead ??
        page.headings
            .filter((heading) => heading.level === 2)
            .map((heading) => heading.text)
            .join(' · ')
    const row = (page) =>
        `<li><a href="${page.url}"><strong>${escapeHTML(page.label === 'Overview' ? page.title : page.label)}</strong><span>${escapeHTML(about(page))}</span></a></li>`
    const groups = sections.map(
        (section) => `        <section class="docs-group">
            <h2>${escapeHTML(section.title)}</h2>
            <ul>${section.pages.map(row).join('')}</ul>
        </section>`,
    )
    const main = `        <div class="prose">
            <h1>Documentation</h1>
            <p>How to install ${site.name}, what it does, and how it is built.</p>
        </div>
${groups.join('\n')}`
    return layout({
        title: 'Documentation',
        description: `The documentation of ${site.name}: how to install it, what it does, and how it is built.`,
        path: '/docs/',
        body: docsFrame({ sections, current: null, main }),
        styles: ['docs'],
        scripts: ['docs'],
    })
}

/** The landing page, around what src/home.html says. */
export function homePage(body) {
    return layout({
        description: site.description,
        path: '/',
        body: `<main>\n${body}</main>`,
        styles: ['home'],
        scripts: ['home'],
        themeColor: { light: '#69aef2', dark: '#0c2342' },
    })
}

export function notFoundPage() {
    return layout({
        title: 'Page not found',
        description: 'This page does not exist.',
        path: '/404.html',
        body: `${header()}
<main class="not-found">
    <h1>Page not found</h1>
    <p>There is nothing at this address.</p>
    <a class="button button-plain" href="/">Go to the start</a>
</main>`,
    })
}
