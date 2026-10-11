// Serves the built site on this Mac, the way the host will: a folder's `index.html` at the folder's
// address, and `404.html` for what isn't there.

import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { createServer } from 'node:http'
import path from 'node:path'

const types = {
    '.css': 'text/css; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
    '.jpg': 'image/jpeg',
    '.js': 'text/javascript; charset=utf-8',
    '.md': 'text/markdown; charset=utf-8',
    '.png': 'image/png',
    '.svg': 'image/svg+xml',
    '.txt': 'text/plain; charset=utf-8',
    '.xml': 'application/xml; charset=utf-8',
}

async function fileAt(root, pathname) {
    const file = path.join(root, decodeURIComponent(pathname))
    // Nothing outside the folder that is served.
    if (file !== root && !file.startsWith(root + path.sep)) return null
    const info = await stat(file).catch(() => null)
    if (info?.isFile()) return file
    if (info?.isDirectory()) {
        const index = path.join(file, 'index.html')
        if ((await stat(index).catch(() => null))?.isFile()) return index
    }
    return null
}

export function serve(root, port) {
    const server = createServer(async (request, response) => {
        // An address that can't be read, or a name that can't be decoded, is a page that isn't there.
        const found = await Promise.resolve()
            .then(() => fileAt(root, new URL(request.url, 'http://localhost').pathname))
            .catch(() => null)
        const file = found ?? path.join(root, '404.html')
        response.writeHead(found ? 200 : 404, {
            'content-type': types[path.extname(file)] ?? 'application/octet-stream',
            'cache-control': 'no-store',
        })
        createReadStream(file)
            .on('error', () => response.end())
            .pipe(response)
    })
    return new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(port, 'localhost', () => resolve(server))
    })
}
