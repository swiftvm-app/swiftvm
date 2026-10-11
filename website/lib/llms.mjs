// The documentation for language models, the way llmstxt.org describes it: `llms.txt` lists every page
// with a line about it, and `llms-full.txt` is all of them in one file. Both lead to the pages as
// Markdown, which the site keeps next to the HTML at the address docs/ gives them.

import { site } from './config.mjs'

/** Where a page of docs/ is on the site as Markdown: `features/ssh.md` at `/docs/features/ssh.md`. */
const markdownURL = (source) => `${site.url}/docs/${encodeURI(source)}`

const introduction = `# ${site.name}

> ${site.description}

${site.name} runs on ${site.requirements}. Install it with \`${site.brew}\`, or download it from ${site.download}. The source is at ${site.repository}.`

export function llmsIndex({ sections }) {
    const entry = (page) => `- [${page.title}](${markdownURL(page.source)})${page.lead ? `: ${page.lead}` : ''}`
    const lists = sections.map((section) => `## ${section.title}\n\n${section.pages.map(entry).join('\n')}`)
    return `${introduction}

Every page below is Markdown. [llms-full.txt](${site.url}/llms-full.txt) has all of them in one file.

${lists.join('\n\n')}
`
}

/** Every page in one file, each as it is in docs/ and under the address its links are relative to. */
export function llmsFull({ ordered }) {
    const pages = ordered.map((page) => `Source: ${markdownURL(page.source)}\n\n${page.text.trim()}`)
    return `${introduction}\n\nThe pages follow, each under the address it has as Markdown. The links in a page are relative to that address.\n\n---\n\n${pages.join('\n\n---\n\n')}\n`
}
