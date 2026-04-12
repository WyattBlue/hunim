---
title: Getting Started
desc: Learn how to install Hunim and create your first static site.
---

# Getting Started

Hunim is a static site generator written in [Nim](https://nim-lang.org). It converts Markdown files into a complete website using templates, components, and optional NimScript execution.

## Installation

Install via Nimble (requires the Nim toolchain):

```
nimble install https://github.com/basswood-io/hunim
```

To build from source, clone the repo and run:

```
git clone https://github.com/basswood-io/hunim
cd hunim
nimble make
```

## Create a new site

```
hunim newsite mysite
cd mysite
```

This scaffolds the following structure:

```
mysite/
├── hunim.toml       # Site configuration
├── src/             # Source files (Markdown, HTML, assets)
├── templates/       # HTML templates
└── components/      # Reusable HTML snippets
```

## Start the dev server

```
hunim server
```

The server runs at `http://127.0.0.1:8080` and automatically rebuilds whenever you save a file. Press `Ctrl+C` to stop.

## Build for production

```
hunim
```

Output is written to `public/`. Deploy the contents of that directory to any static host (GitHub Pages, Netlify, Cloudflare Pages, etc.).

## Project layout

| Path | Purpose |
|------|---------|
| `hunim.toml` | Site-wide configuration |
| `src/` | Content: Markdown files, HTML files, and assets |
| `templates/` | HTML wrappers applied to Markdown pages |
| `components/` | Reusable HTML snippets and NimScripts |
| `public/` | Build output (generated, do not edit) |

## Next steps

- [Configuration](/configuration) — set your base URL and language code
- [Templates](/templates) — build reusable HTML layouts
- [Frontmatter](/frontmatter) — add titles, dates, and metadata to pages
- [Components](/components) — create reusable snippets
- [Feeds](/feeds) — set up a blog with automatic RSS
- [CLI Reference](/cli) — all commands and flags
