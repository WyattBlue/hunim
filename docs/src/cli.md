---
title: CLI Reference
desc: All Hunim commands and flags.
---

# CLI Reference

## Commands

### `hunim`

Build the site. Reads from `src/`, writes to `public/`.

```
hunim [--buildDrafts]
```

| Flag | Description |
|------|-------------|
| `--buildDrafts` | Include pages with `draft: true` in the build. |

---

### `hunim server`

Start the development server with hot reload.

```
hunim server [--buildDrafts]
```

- Serves the built site at `http://127.0.0.1:8080`.
- Watches `src/` for changes and rebuilds automatically.
- Injects the `{{ .Reload }}` auto-reload script into every page (polls every 100 ms).
- Press `Ctrl+C` to stop.

| Flag | Description |
|------|-------------|
| `--buildDrafts` | Include draft pages in the server build. |

---

### `hunim newsite`

Scaffold a new site directory.

```
hunim newsite <name>
```

Creates a directory called `<name>` containing:

```
<name>/
├── hunim.toml
├── src/
│   └── index.html
├── templates/
└── components/
```

---

### `hunim version`

Print the installed version number and exit.

```
hunim version
```

## Build output

All commands write to the `public/` directory:

| File | Description |
|------|-------------|
| `public/**/*.html` | Converted Markdown and copied HTML files |
| `public/sitemap.xml` | Sitemap with all indexed pages |
| `public/{feed}/index.xml` | RSS feed for each feed directory |

## URL structure

Markdown files are converted and their paths are cleaned:

| Source | Output URL |
|--------|-----------|
| `src/index.md` | `/` |
| `src/about.md` | `/about` |
| `src/index.md` | `/` |
| `src/templates.md` | `/templates` |

Static assets (images, CSS, JS) are copied as-is without modification.
