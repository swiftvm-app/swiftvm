# Website

The site at [swiftvm.app](https://swiftvm.app): a landing page, and the pages of
[`docs/`](../docs/README.md) as HTML.

The pages of `docs/` are the only copy of the documentation. The site is built
from them, so a change to a page there is a change to the site.

## Working on it

It needs [Node.js](https://nodejs.org) 22 or newer.

```bash
cd website
npm install
npm run dev      # builds, serves http://localhost:4173, and builds again when a page changes
npm run build    # the site, in website/dist
```

| | |
| --- | --- |
| `src/home.html` | The landing page. `{{doc:features/ssh.md}}` is a link to a page of `docs/` |
| `src/assets/` | Stylesheets and scripts. `panel.js` draws the panel of the hero, for the build and for the page |
| `src/static/` | Files that go to the site as they are |
| `lib/` | The build: Markdown, navigation, the pages' frame, `llms.txt` |
| `build.mjs` | Puts it all in `dist/` |

## What the build does

- **Pages.** `docs/features/ssh.md` becomes `/docs/features/ssh/`. A folder's
  `README.md` becomes the folder's own page.
- **Navigation.** Each folder of `docs/` is a section. Its pages come in the
  order the folder's `README.md` links to them, or else the order
  `docs/README.md` does. A new page shows up by itself, and where you link to
  it decides its place.
- **Links.** Links between pages lead to the site, links to other files of the
  repository to GitHub. The build fails on a link that leads nowhere, and on
  one that names a section its page doesn't have.
- **Pictures.** A picture a page shows is copied to the site from its place in
  `docs/`. The build fails on one that isn't there.
- **Diagrams.** `mermaid` blocks are drawn in the browser. The script comes
  with the site and is loaded only by pages that have a diagram.
- **For language models.** `/llms.txt` lists every page, `/llms-full.txt` is
  all of them in one file, and every page is also there as Markdown, at
  `/docs/features/ssh.md`.

## The hero

The landing page's hero is the app's menu bar panel, made after
[`App/MenuBar`](../App/MenuBar): the same sizes, labels, and menus. When the
panel changes in the app, change it in `src/assets/panel.js` and
`src/assets/home.css`.

It is night there in the dark appearance and day in the light one, and the
panel is the app's in each. The page follows the system until a visitor turns
it with the sun or moon in the menu bar. Every colour that differs between the
two is written once, as `light-dark()`.

`src/static/og.jpg`, the picture that stands for the site where a link to it is
shared, is a capture of the hero at 1200 × 630.

## Deploying

The site is on [Cloudflare Pages](https://pages.cloudflare.com), which builds
it on every push to `main` and builds a preview of every pull request. To set
it up:

1. In the Cloudflare dashboard, go to **Workers & Pages** and choose
   **Create application → Pages → Connect to Git**.
2. Sign in with GitHub, give Cloudflare access to this repository, and choose
   **Begin setup**.
3. Fill in the build settings and choose **Save and Deploy**:

   | Setting | Value |
   | --- | --- |
   | Production branch | `main` |
   | Framework preset | None |
   | Build command | `npm run build` |
   | Build output directory | `dist` |
   | Root directory (advanced) | `website` |

4. In the project, open **Custom domains**, choose **Set up a domain**, and
   enter `swiftvm.app`. With the domain's DNS on Cloudflare, the record is
   added for you.

- Leave **Build watch paths** as they are. Limited to `website/`, a change to
  `docs/` wouldn't build the site.
- `.node-version` tells Cloudflare which Node.js to build with.
- `src/static/_headers` sets the headers the site's files are sent with.

Any other host of static files works the same way: run `npm run build` in
`website/` and serve `website/dist`.
