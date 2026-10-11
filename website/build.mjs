#!/usr/bin/env node
// Builds the site into dist/: the landing page, a page for every page of docs/, and what goes with them.
//
//   node build.mjs            builds once
//   node build.mjs --serve    builds, serves the site on this Mac, and builds again when a page changes

import { spawn } from 'node:child_process'
import { watch } from 'node:fs'
import { mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { site } from './lib/config.mjs'
import { loadDocs, renderPage } from './lib/docs.mjs'
import { llmsFull, llmsIndex } from './lib/llms.mjs'
import { serve } from './lib/serve.mjs'
import { starTiles } from './lib/stars.mjs'
import { appearanceButton, docsIndex, docsPage, homePage, notFoundPage } from './lib/templates.mjs'
import { escapeHTML, headline, initialMachines, renderList } from './src/assets/panel.js'

const website = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.dirname(website)
const outDirectory = path.join(website, 'dist')

async function filesIn(directory, base = directory) {
    const entries = await readdir(directory, { withFileTypes: true })
    const found = await Promise.all(
        entries.map((entry) => {
            const full = path.join(directory, entry.name)
            if (entry.isDirectory()) return filesIn(full, base)
            return entry.name === '.DS_Store' ? [] : [path.relative(base, full).split(path.sep).join('/')]
        }),
    )
    return found.flat()
}

/** src/home.html with its `{{…}}` filled in. A link to a page of docs/ is written `{{doc:features/ssh.md}}`. */
function fillHome(template, { pages, problems }) {
    const machines = initialMachines()
    const values = {
        'panel.list': renderList({ machines }),
        'panel.headline': escapeHTML(headline(machines)),
        appearance: appearanceButton('menubar-extra menubar-appearance'),
        ...Object.fromEntries(Object.entries(site).map(([key, value]) => [`site.${key}`, escapeHTML(value)])),
    }
    return template.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (match, key) => {
        if (Object.hasOwn(values, key)) return values[key]
        if (key.startsWith('doc:')) {
            const [source, anchor] = key.slice(4).split('#')
            const page = pages.get(source)
            if (!page) problems.push(`src/home.html: ${match} names a page that docs/ doesn't have`)
            else if (anchor && !page.headings.some((heading) => heading.id === anchor)) {
                problems.push(`src/home.html: ${match} names a section that docs/${source} doesn't have`)
            }
            return (page?.url ?? '') + (anchor ? `#${encodeURIComponent(anchor)}` : '')
        }
        problems.push(`src/home.html: ${match} isn't something the build knows`)
        return match
    })
}

/**
 * Everything the site is made of, by its path in dist/.
 *
 * @returns `files`, a map from path to text or bytes, and `problems`: what is wrong with the pages,
 *   such as a link that leads nowhere. A site with problems isn't written.
 */
async function renderSite() {
    const docsDirectory = path.join(repositoryRoot, 'docs')
    const files = new Map()
    const problems = []

    const docs = await loadDocs(docsDirectory)
    const attachments = new Set()
    const context = { ...docs, repositoryRoot, docsDirectory, site, problems, attachments }

    // The pages of docs/: each as HTML at its address, and next to it the Markdown it is and the
    // pictures it shows.
    for (const page of docs.ordered) {
        const { html, hasDiagram } = renderPage(page, context)
        page.hasDiagram = hasDiagram
        if (files.has(page.file)) problems.push(`docs/${page.source} would be at ${page.url}, where another page already is`)
        files.set(page.file, docsPage({ page, html, ...docs }))
    }
    for (const page of docs.pages.values()) files.set(`docs/${page.source}`, page.text)
    for (const source of attachments) files.set(`docs/${source}`, await readFile(path.join(docsDirectory, ...source.split('/'))))
    files.set('docs/index.html', docsIndex(docs))

    files.set('index.html', homePage(fillHome(await readFile(path.join(website, 'src/home.html'), 'utf8'), context)))
    files.set('404.html', notFoundPage())
    files.set('llms.txt', llmsIndex(docs))
    files.set('llms-full.txt', llmsFull(docs))

    const addresses = ['/', '/docs/', ...docs.ordered.map((page) => page.url)]
    files.set(
        'sitemap.xml',
        `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${addresses
            .map((address) => `<url><loc>${site.url}${address}</loc></url>`)
            .join('\n')}\n</urlset>\n`,
    )
    files.set('robots.txt', `User-agent: *\nAllow: /\n\nSitemap: ${site.url}/sitemap.xml\n`)

    // What the pages are drawn with.
    for (const name of await filesIn(path.join(website, 'src/assets'))) {
        files.set(`assets/${name}`, await readFile(path.join(website, 'src/assets', name)))
    }
    for (const name of await filesIn(path.join(website, 'src/static'))) {
        files.set(name, await readFile(path.join(website, 'src/static', name)))
    }
    files.set('assets/logo.svg', await readFile(path.join(repositoryRoot, 'assets/logo.svg')))
    for (const [name, tile] of Object.entries(starTiles())) files.set(`assets/${name}`, tile)
    if (docs.ordered.some((page) => page.hasDiagram)) {
        const mermaid = path.join(website, 'node_modules/@mermaid-js/tiny/dist/mermaid.tiny.js')
        files.set('assets/vendor/mermaid.js', await readFile(mermaid))
    }

    return { files, problems }
}

/** Writes the site to dist/, in place of what was there. Throws, and writes nothing, if a page has a problem. */
async function build() {
    const { files, problems } = await renderSite()
    if (problems.length > 0) {
        throw new Error(`The site wasn't built:\n${problems.map((problem) => `  - ${problem}`).join('\n')}`)
    }
    await rm(outDirectory, { recursive: true, force: true })
    for (const [name, content] of files) {
        const file = path.join(outDirectory, ...name.split('/'))
        await mkdir(path.dirname(file), { recursive: true })
        await writeFile(file, content)
    }
    return files.size
}

async function main() {
    if (!process.argv.includes('--serve')) {
        const started = performance.now()
        const count = await build()
        console.log(`Built ${count} files in ${Math.round(performance.now() - started)} ms.`)
        return
    }

    // Every build is a process of its own, so that it runs what the files say now and not what they
    // said when this one started.
    const rebuild = () =>
        new Promise((resolve) => {
            spawn(process.execPath, [fileURLToPath(import.meta.url)], { stdio: 'inherit' }).once('exit', resolve)
        })
    await rebuild()
    const port = Number(process.env.PORT ?? 4173)
    await serve(outDirectory, port)
    console.log(`Serving http://localhost:${port}`)

    // Builds again a moment after the last change, so that saving several files builds once, and never
    // twice at the same time.
    let pending
    let building = Promise.resolve()
    const changed = () => {
        clearTimeout(pending)
        pending = setTimeout(() => {
            building = building.then(rebuild)
        }, 120)
    }
    for (const directory of ['src', 'lib', '../docs', '../assets']) {
        watch(path.join(website, directory), { recursive: true }, changed)
    }
}

main().catch((error) => {
    console.error(error.message)
    process.exitCode = 1
})
