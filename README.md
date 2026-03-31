
## Overview

Hunim is a static site generator written in [Nim](https://nim-lang.org). Small, fast, and unopinionated, it's ready to meet your needs.

## Choose How to Install

```
nimble install https://github.com/WyattBlue/hunim
```

If you want to contribute, fork this repo, clone it, then run:
```
nimble make
```
to build the binary.

## Usage

Start a new site:
```
hunim newsite mysite
cd mysite
```

Start the development server:
```
hunim server
```

`Ctrl^C` to stop.

When you are ready to deploy your site, run:

```
hunim
```

This publishing the files to the `public` directory.

## Features

Run NimScript with:
```
{{ exec my_script.nims }}
```
This will replace the contents with the output of the script in `components/my_script.nims`.
