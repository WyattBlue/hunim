---
title: Feeds
desc: Set up a blog with automatic RSS feed generation.
---

# Feeds

Hunim's feed system turns any directory into a blog with automatic post indexing and RSS feed generation.

## Enabling a feed

Add an `index.md` to a directory with `type: feed` in its frontmatter:

```
src/
  blog/
    index.md       ← type: feed
    first-post.md
    second-post.md
```

`src/blog/index.md`:

```markdown
---
title: My Blog
type: feed
---

Welcome to my blog!
```

Hunim will:

1. Collect all `.md` files in `blog/` (except `index.md`) as posts.
2. Sort posts by `date` descending (newest first).
3. Render each post using `templates/blog_list.html` (if it exists).
4. Generate `public/blog/index.xml` — a valid RSS feed.

## Feed template

Create a template named after the feed directory with a `_list` suffix:

| Feed directory | Template file |
|----------------|---------------|
| `src/blog/` | `templates/blog_list.html` |
| `src/news/` | `templates/news_list.html` |
| `src/articles/` | `templates/articles_list.html` |

If the template does not exist, Hunim falls back to `templates/default.html`.

## Post frontmatter

Each post should include `title`, `date`, and optionally `author` and `desc`:

```markdown
---
title: My First Post
author: Jane Doe
date: Mon, 19 Nov 2024 12:00:00 PST
desc: An introduction to my new blog.
---

# My First Post

Content goes here.
```

Posts without a `date` appear at the end of the list (after all dated posts).

## RSS feed

Hunim generates a standards-compliant RSS 2.0 feed at `{feeddir}/index.xml`. The feed uses:

- `title` — from `hunim.toml`
- `link` — from `baseURL` in `hunim.toml`
- Each item's `title`, `link`, `pubDate`, and `description` — from post frontmatter

Link to the feed from your template:

```html
<link rel="alternate" type="application/rss+xml"
      title="My Blog" href="/blog/index.xml">
```

## Example structure

```
src/
  blog/
    index.md              # type: feed
    hello-world.md
    second-post.md

templates/
  blog_list.html          # Applied to individual posts

public/                   # Generated output
  blog/
    index.html
    index.xml             # RSS feed
    hello-world/
      index.html
    second-post/
      index.html
```
