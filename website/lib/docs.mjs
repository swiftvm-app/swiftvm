// Turns the Markdown pages of docs/ into the pages of the site: reads them, works out the navigation
// from the way they link to each other, and renders each with its links pointing at the site.

import { readdirSync } from 'node:fs'
import { readdir, readFile } from 'node:fs/promises'
import path from 'node:path'
import MarkdownIt from 'markdown-it'

import { escapeHTML } from '../src/assets/panel.js'

const posix = path.posix

// MARK: Headings

/** The anchor GitHub gives a heading, so that links between the pages work in both places. */
function slugify(text) {
    return text
        .toLowerCase()
        .replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '')
        .replace(/ /g, '-')
}

/**
 * Anchors for the headings of one page. A second heading of the same name gets `-1`, as on GitHub, and
 * the next free number if a heading already has that name.
 */
function createSlugger() {
    const counts = new Map()
    return (text) => {
        const name = slugify(text)
        let slug = name
        while (counts.has(slug)) {
            counts.set(name, counts.get(name) + 1)
            slug = `${name}-${counts.get(name)}`
        }
        counts.set(slug, 0)
        return slug
    }
}

/** What an inline token says, without its markup. */
function plainText(token) {
    return (token.children ?? [])
        .map((child) => (child.type === 'softbreak' || child.type === 'hardbreak' ? ' ' : child.content))
        .join('')
}

// MARK: Markdown

/** Dims the comments of a shell example. Nothing else in one needs telling apart. */
function highlightShell(code) {
    return code
        .split('\n')
        .map((line) => {
            const comment = line.match(/(^|\s)#.*$/)
            if (!comment) return escapeHTML(line)
            const start = comment.index + comment[1].length
            return `${escapeHTML(line.slice(0, start))}<span class="comment">${escapeHTML(line.slice(start))}</span>`
        })
        .join('\n')
}

function createMarkdown() {
    // Raw HTML stays text: the pages don't use any, and nothing a page says should become markup.
    const markdown = new MarkdownIt({ html: false })
    const { rules } = markdown.renderer

    // Every heading gets its anchor, and the page remembers its headings for the outline. A heading of
    // nothing but punctuation has no name to make one from, and goes without.
    markdown.core.ruler.push('headings', (state) => {
        const slug = createSlugger()
        state.env.headings = []
        state.tokens.forEach((token, index) => {
            if (token.type !== 'heading_open') return
            const text = plainText(state.tokens[index + 1])
            const id = slug(text)
            if (id === '') return
            token.attrSet('id', id)
            state.env.headings.push({ level: Number(token.tag.slice(1)), id, text })
        })
    })

    rules.heading_close = (tokens, index, options, env, self) => {
        const open = tokens.findLast((token, at) => at < index && token.type === 'heading_open')
        const id = open.attrGet('id')
        const anchor = open.tag === 'h1' || !id ? '' : `<a class="anchor" href="#${encodeURIComponent(id)}" aria-label="Link to this section">#</a>`
        return anchor + self.renderToken(tokens, index, options)
    }

    // The tokens keep what the page wrote, so that a page can be rendered more than once.
    rules.link_open = (tokens, index, options, env, self) => {
        const attrs = tokens[index].attrs.map(([name, value]) => [name, name === 'href' ? env.resolve(value) : value])
        return `<a${self.renderAttrs({ attrs })}>`
    }

    rules.image = (tokens, index, options, env, self) => {
        const token = tokens[index]
        const attrs = token.attrs.map(([name, value]) => {
            if (name === 'src') return [name, env.attach(value)]
            return [name, name === 'alt' ? self.renderInlineAsText(token.children, options, env) : value]
        })
        return `<img${self.renderAttrs({ attrs })}>`
    }

    rules.fence = (tokens, index, options, env) => {
        const token = tokens[index]
        const language = token.info.trim().split(/\s+/)[0]
        if (language === 'mermaid') {
            env.hasDiagram = true
            return `<pre class="mermaid">${escapeHTML(token.content)}</pre>\n`
        }
        const code = token.content.replace(/\n$/, '')
        const body = language === 'bash' || language === 'sh' ? highlightShell(code) : escapeHTML(code)
        return `<div class="code"><pre><code>${body}</code></pre></div>\n`
    }

    // A wide table scrolls by itself instead of widening the page. One whose header row is empty, as
    // GitHub needs it for a table of two plain columns, is shown without it.
    rules.table_open = (tokens, index) => {
        const end = tokens.findIndex((token, at) => at > index && token.type === 'thead_close')
        const header = tokens.slice(index, end).filter((token) => token.type === 'inline')
        const isHeadless = header.every((token) => token.content.trim() === '')
        return `<div class="table"><table${isHeadless ? ' class="is-headless"' : ''}>\n`
    }
    rules.table_close = () => '</table></div>\n'

    return markdown
}

const markdown = createMarkdown()

// MARK: Pages

async function findMarkdown(directory, base = directory) {
    const entries = await readdir(directory, { withFileTypes: true })
    const found = await Promise.all(
        entries.map((entry) => {
            const full = path.join(directory, entry.name)
            if (entry.isDirectory()) return findMarkdown(full, base)
            return entry.name.endsWith('.md') ? [path.relative(base, full).split(path.sep).join('/')] : []
        }),
    )
    return found.flat().sort()
}

/**
 * Where a page of docs/ is on the site: `features/ssh.md` at `/docs/features/ssh/`, a `README.md` at its
 * folder. `url` is the address, and `file` the file in dist/ that is served there.
 */
function placeOf(source) {
    const directory = posix.dirname(source)
    const name = posix.basename(source, '.md')
    const parts = ['docs', ...(directory === '.' ? [] : directory.split('/')), ...(name === 'README' ? [] : [name])]
    return { url: `/${parts.map(encodeURIComponent).join('/')}/`, file: `${parts.join('/')}/index.html` }
}

/** `user-guide` as a title: `User guide`. */
function titleOf(directory) {
    const words = directory.replace(/[-_]+/g, ' ')
    return words.charAt(0).toUpperCase() + words.slice(1)
}

/** The pages a page links to, in the order it does. */
function linkedPages(page, pages) {
    const found = []
    const visit = (tokens) => {
        for (const token of tokens) {
            if (token.type === 'link_open' && !isExternal(token.attrGet('href'))) {
                const { source } = targetOf(token.attrGet('href'), page)
                if (source !== page.source && pages.has(source) && !found.includes(source)) found.push(source)
            }
            if (token.children) visit(token.children)
        }
    }
    visit(page.tokens)
    return found
}

/**
 * Reads docs/ and works out its pages and its navigation.
 *
 * The navigation follows the pages themselves, so that docs/ stays the only place to keep up to date:
 * - Each folder is a section. A folder's `README.md` gives the section its title and is its first page.
 * - The pages of a section come in the order its `README.md` links to them, or else the order
 *   `docs/README.md` does. Pages that nothing links to come last.
 * - `docs/README.md` itself is the list of everything, which the site draws on its own. Other pages
 *   that are in no folder make a section of their own, ahead of the folders.
 */
export async function loadDocs(docsDirectory) {
    const pages = new Map()
    for (const source of await findMarkdown(docsDirectory)) {
        const text = await readFile(path.join(docsDirectory, ...source.split('/')), 'utf8')
        const env = {}
        const tokens = markdown.parse(text, env)
        const title = env.headings.find((heading) => heading.level === 1)?.text ?? titleOf(posix.basename(source, '.md'))
        pages.set(source, {
            source,
            ...placeOf(source),
            title,
            text,
            tokens,
            env,
            headings: env.headings,
            lead: leadOf(tokens),
        })
    }

    const index = pages.get('README.md')
    const indexOrder = index ? linkedPages(index, pages) : []
    const folders = [...new Set([...pages.keys()].filter((source) => source.includes('/')).map((source) => source.split('/')[0]))]
    const rank = (list, item) => (list.includes(item) ? list.indexOf(item) : Infinity)
    const inOrder = (order) => (a, b) => rank(order, a.source) - rank(order, b.source) || a.source.localeCompare(b.source)
    folders.sort((a, b) => {
        const first = (folder) => indexOrder.findIndex((source) => source.startsWith(`${folder}/`))
        const [rankA, rankB] = [first(a), first(b)].map((value) => (value < 0 ? Infinity : value))
        return rankA - rankB || a.localeCompare(b)
    })

    const sections = folders.map((folder) => {
        const overview = pages.get(`${folder}/README.md`)
        const members = [...pages.values()]
            .filter((page) => page.source.startsWith(`${folder}/`) && page !== overview)
            .sort(inOrder(overview ? linkedPages(overview, pages) : indexOrder))
        return {
            title: overview?.title ?? titleOf(folder),
            pages: [...(overview ? [overview] : []), ...members],
            overview,
        }
    })
    const loose = [...pages.values()].filter((page) => !page.source.includes('/') && page !== index)
    if (loose.length > 0) sections.unshift({ title: 'General', pages: loose.sort(inOrder(indexOrder)) })

    // The label a page has in the navigation: a section's own page is its overview.
    for (const section of sections) {
        for (const page of section.pages) {
            page.section = section
            page.label = page === section.overview ? 'Overview' : page.title
        }
    }
    return { pages, sections, ordered: sections.flatMap((section) => section.pages) }
}

/** The paragraph a page opens with, as text, if that is what follows its title. */
function leadOf(tokens) {
    const index = tokens.findIndex((token) => token.level === 0 && token.tag !== 'h1')
    return tokens[index]?.type === 'paragraph_open' ? plainText(tokens[index + 1]).replace(/\s+/g, ' ').trim() : null
}

// MARK: Links

const isExternal = (href) => /^([a-z][a-z0-9+.-]*:|\/\/)/i.test(href)

/** markdown-it hands links over percent-encoded. The names of files and sections are not. */
function decode(text) {
    try {
        return decodeURIComponent(text)
    } catch {
        return text
    }
}

/**
 * What a link in a page points at: the file, as a path from docs/, and the section in it.
 *
 * A link that starts with a slash is read from the top of the repository, as GitHub reads it.
 */
function targetOf(href, page) {
    const [target = '', anchor = ''] = href.split('#').map(decode)
    if (target === '') return { source: page.source, anchor }
    const source = target.startsWith('/')
        ? posix.relative('docs', posix.normalize(target.slice(1)))
        : posix.normalize(posix.join(posix.dirname(page.source), target))
    return { source, anchor }
}

/** Whether a file is there under exactly this name. A Mac's disk also finds `LICENSE` as `license`; the host's doesn't. */
function existsExactly(root, relative) {
    let directory = root
    for (const name of relative.split('/').filter(Boolean)) {
        try {
            if (!readdirSync(directory).includes(name)) return false
        } catch {
            return false
        }
        directory = path.join(directory, name)
    }
    return true
}

/**
 * Where a link in a page of docs/ leads on the site.
 *
 * - A link to another page of docs/ leads to that page of the site.
 * - A link to another file of the repository leads to the file on GitHub.
 * - A link to something that isn't there is a problem, which fails the build.
 *
 * @param problems Collects what is wrong, so that one build reports every broken link.
 */
function resolveLink(href, page, { pages, repositoryRoot, site, problems }) {
    if (isExternal(href)) return href

    const { source, anchor } = targetOf(href, page)
    const fragment = anchor ? `#${encodeURIComponent(anchor)}` : ''
    const complain = (what) => problems.push(`docs/${page.source}: the link to "${decode(href)}" ${what}`)

    const destination = pages.get(source) ?? pages.get(posix.join(source, 'README.md'))
    if (destination) {
        // The first page of the documentation is the site's own list of the pages, which has none of the
        // sections that docs/README.md has.
        if (destination.source === 'README.md') return destination.url
        if (anchor && !destination.headings.some((heading) => heading.id === anchor)) {
            complain(`names a section that ${destination === page ? 'this page' : `docs/${destination.source}`} doesn't have`)
        }
        return (href.startsWith('#') ? '' : destination.url) + fragment
    }

    // Not a page: a file somewhere else in the repository, if it is one.
    const relative = posix.join('docs', source)
    if (!relative.startsWith('..') && existsExactly(repositoryRoot, relative)) {
        return `${site.repository}/blob/${site.branch}/${encodeURI(relative)}${fragment}`
    }
    complain("leads to a file that doesn't exist")
    return href
}

/**
 * Where a picture in a page of docs/ is on the site: next to the page's Markdown, at the place it has
 * in docs/. The build copies it there.
 *
 * @param attachments Collects the files to copy, as paths from docs/.
 */
function attachFile(src, page, { docsDirectory, attachments, problems }) {
    if (isExternal(src)) return src

    const { source } = targetOf(src, page)
    if (source.startsWith('..') || !existsExactly(docsDirectory, source)) {
        problems.push(`docs/${page.source}: the picture "${decode(src)}" isn't a file in docs/`)
        return src
    }
    attachments.add(source)
    return `/docs/${encodeURI(source)}`
}

/** A page as HTML, with what the layout needs to know about it. */
export function renderPage(page, context) {
    const env = {
        ...page.env,
        resolve: (href) => resolveLink(href, page, context),
        attach: (src) => attachFile(src, page, context),
        hasDiagram: false,
    }
    const html = markdown.renderer.render(page.tokens, markdown.options, env)
    return { html, hasDiagram: env.hasDiagram }
}
