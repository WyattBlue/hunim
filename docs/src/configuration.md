---
title: Configuration
desc: Configure your Hunim site with hunim.toml.
---

# Configuration

Every Hunim site has a `hunim.toml` file at the project root. This file controls site-wide settings used during the build.

## hunim.toml

```toml
baseURL      = 'https://example.com/'
languageCode = 'en-us'
title        = 'My Site'
```

All three fields are required.

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `baseURL` | string | The root URL of your deployed site. **Must end with `/`**. Used for sitemap URLs and RSS feed links. |
| `languageCode` | string | An [RFC 5646](https://www.rfc-editor.org/rfc/rfc5646) language tag (e.g. `en-us`, `fr`, `de`). Exposed as `{{ .Lang }}` in templates. |
| `title` | string | The name of your site. Used in RSS feed metadata. |

## Example

```toml
baseURL      = 'https://mysite.dev/'
languageCode = 'en-us'
title        = 'My Awesome Site'
```

> The `baseURL` must end with a trailing slash, otherwise sitemap and feed URLs will be malformed.
