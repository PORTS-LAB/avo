# Avo website

The public website for Avo, in English and Indonesian: a single landing page
plus a 404 page, built by a small Node script. Plain HTML, CSS and
JavaScript; no framework, no npm dependencies, no cookies, no analytics. It
is hosted on GitHub Pages as is.

## Contents

```
website/
├── site.config.mjs          Everything to fill in or decide: URLs, release state, contact,
│                            support channels, typeface set
├── src/
│   ├── pages/               index.html (landing page), 404.html
│   ├── partials/            head, header, footer, SVG sprite
│   ├── i18n/en.json, id.json  All wording, English and Indonesian (same keys; the build checks)
│   └── assets/              css/site.css, css/fonts/ (one file per typeface set), js/ (site
│                            behaviour, WebGL haze), fonts/ (one folder per family, each with
│                            its OFL.txt), img/ (Avo mark and icon from branding/, favicons, og/,
│                            screens/: screenshots of Avo in AVIF, WebP and JPEG at 640 px and
│                            full width, with player names and device IDs blurred)
├── tools/
│   ├── build.mjs            Builds dist/ (npm run build); --strict refuses placeholders
│   ├── serve.mjs            Local development server with rebuild on change
│   ├── screenshots.mjs      Headless Chrome screenshots and layout checks
│   └── og-image.html        Template for the social preview images (src/assets/img/og/)
├── tests/                   node --test: the built site (both languages, links, no emoji,
│                            CSP-friendly markup, configuration switches)
├── deploy/github-pages.yml  GitHub Actions workflow to copy into .github/workflows/
└── dist/                    Build output (ignored by git)
```

## Requirements

Node.js 22.5 or later. Nothing to install with npm.

## Configure

Everything you need to fill in is in **`site.config.mjs`**, with comments.
Placeholders contain `OWNER`, `TODO` or `example.org`; `npm run build` lists
the ones left and `npm run build:strict` refuses to build until none are.

| Setting | What it is |
| --- | --- |
| `siteUrl` | Public address of the site (`https://nizwar.github.io/avo`, or a custom domain). Used for canonical links, the sitemap and social previews. |
| `githubUrl`, `githubBranch` | The repository and its branch, for links into `docs/`. |
| `release` | `available: false` says plainly that no build is published and offers "Build from source". Set `available: true`, `version` and `downloadUrl` when a release is out. |
| `fonts` | The typeface set, one switch for the whole site: `'hubot-mona'` (A, default: Hubot Sans headings, Mona Sans text, Mona Sans Mono labels), `'geist'` (B), `'archivo'` (C), `'jakarta'` (D, Plus Jakarta Sans). Letters work too. Only the chosen set's files are published. |
| `maintainer.name` | Named in the footer credit ("Made by … in West Kalimantan, with help from Claude."). `null` says "an independent developer". |
| `contact.email` | Public contact address. |
| `support.channels` | Ways to support the developer personally (GitHub Sponsors, Saweria, ...): `name`, `url`, `currency`, `frequency` (`monthly`, `once`, `monthly-or-once`), optional `details` text (for example a bank account). An empty list shows "Support links are coming soon". |

The wording is in `src/i18n/en.json` and `src/i18n/id.json`. Both files must
have the same keys; the build stops if they differ. Strings may contain
`{github}`, `{blob}` and `{contactEmail}`, which the build fills in.

Product claims on the page follow `docs/` and the code. When a feature lands
or changes, update the wording in both languages.

## Local development

```sh
cd website
npm run dev            # build, serve at http://localhost:8788/avo/ and rebuild on change
npm test               # build into a temporary folder and check it
npm run build          # build dist/ only
npm run build:strict   # the same, refusing any placeholder left in site.config.mjs
```

The site is served under the path of `siteUrl` (here `/avo/`), exactly like a
GitHub Pages project site.

Screenshots and layout checks (content wider than the screen, console errors,
HTTP status) with headless Chrome in a throwaway profile, while `npm run dev`
runs:

```sh
node tools/screenshots.mjs --out /tmp/avo-shots [--only home-en] [--views desktop,phone]
```

## Deploy

1. Fill in `site.config.mjs` and check with `npm run build:strict`.
2. Copy `deploy/github-pages.yml` to `.github/workflows/website.yml`.
3. In the repository's Settings › Pages, choose **GitHub Actions** as the
   source. Every push to `main` that touches `website/` runs the tests, builds
   with `--strict` and publishes `website/dist`.

For a custom domain, set it in Settings › Pages and set `siteUrl` to match.

## Checklist before going live

- [ ] Support channels in `site.config.mjs` once their pages are live (GitHub Sponsors, Saweria)
- [ ] Whether to show `maintainer.name`
- [ ] `deploy/github-pages.yml` copied to `.github/workflows/`, Pages source set to GitHub Actions
- [ ] When a release is published: `release.available`, `version`, `downloadUrl`

## Licenses

Code: Apache License 2.0, like the rest of Avo. Typefaces are self-hosted and
all under the SIL Open Font License 1.1, with the license next to each font in
`src/assets/fonts/<family>/OFL.txt`: Hubot Sans, Mona Sans and Mona Sans Mono
(GitHub), Geist and Geist Mono (Vercel), Archivo (Omnibus-Type), Plus Jakarta
Sans (Tokotype) and JetBrains Mono (JetBrains). The files are the Latin files
Google Fonts publishes (Mona Sans Mono: GitHub's release), unmodified, so
families with Reserved Font Names (Hubot, Mona) are not altered. Only the set
chosen in `site.config.mjs` is published. The Avo mark and icon come from
`branding/`.

Typeface sets live in `src/assets/css/fonts/<set>.css`: each declares its
`@font-face` rules and the `--font-display`, `--font-sans`, `--font-mono` and
`--display-*` variables (weight, width, tracking, leading) that `site.css`
uses. To add a set, add the family folder with its license, a CSS file, and
an entry in `FONT_SETS` in `tools/build.mjs`.
