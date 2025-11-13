import std/[algorithm, sequtils, strformat, strutils, terminal, times, os, osproc]

import parsetoml

proc error(msg: string) =
  stderr.styledWriteLine(fgRed, bgBlack, msg, resetStyle)
  quit(1)

proc parseDate(date: string): DateTime =
  # Parse RFC 2822 dates

  let explode = rsplit(date, " ", 1)
  let date2 = explode[0]
  let timezone = explode[1]

  result = parse(date2, "ddd, dd MMM yyyy HH:mm:ss")

  case timezone:
    of "EDT": result -= initDuration(hours = -4)
    of "EST": result -= initDuration(hours = -5)
    else: quit(1)


func shouldProcessFile(path: string): bool =
  if path.endsWith(".DS_Store"):
    return false

  let ext = path.splitFile().ext.toLowerAscii()
  return ext notin [".avif", ".webp", ".png", ".jpeg", ".jpg", ".svg"]

proc parseTemplate(content: string, compName: string, compContent: string): string =
  var newContent = content
  var startIdx = 0
  while true:
    let openIdx = newContent.find("{{ " & compName, startIdx)
    if openIdx == -1:
      break
    let closeIdx = newContent.find(" }}", openIdx)
    if closeIdx == -1 and openIdx != -1:
      stderr.writeLine("error! Unclosed template for " & compName)
      quit(1)
    if closeIdx == -1:
      break

    let fullMatch = newContent[openIdx .. closeIdx + 2]
    let argsStr = newContent[openIdx + compName.len + 3 .. closeIdx - 1].strip()
    let args = argsStr.split('"').filterIt(it.strip() != "")

    var replacedContent = compContent
    for i, arg in args:
      replacedContent = replacedContent.replace("{{ $" & $(i+1) & " }}", arg)

    newContent = newContent.replace(fullMatch, replacedContent)
    startIdx = openIdx + replacedContent.len

  return newContent

proc processFile(path: string) =
  if not shouldProcessFile(path):
    return

  var content = readFile(path)

  for kind, comp in walkDir("components"):
    let compName = comp.extractFilename().changeFileExt("")
    if kind == pcFile and not compName.startsWith("."):
      let compContent = readFile(comp).strip()
      content = parseTemplate(content, compName, compContent)
  
  var outputPath = path
  if path.endsWith("index.html"):
    outputPath = path
  elif path.endsWith(".html"):
    outputPath = path.splitFile().dir / path.splitFile().name

  writeFile(outputPath, content)
  
  if outputPath != path:
    removeFile(path)
    echo "Processed and renamed: ", path, " -> ", outputPath
  else:
    echo "Processed: ", path

proc processDirectory(dir: string) =
  for kind, path in walkDir(dir):
    if kind == pcFile:
      processFile(path)
    elif kind == pcDir:
      processDirectory(path)

################################
#  Markdown -> HTML converter  #
################################

type
  PragmaKind = enum
    normalType,
    blogType,

  TokenKind = enum
    tkBar,
    keyval,
    tkText,
    tkH1,
    tkH2,
    tkH3,
    tkNewline,
    tkTick,
    tkList,
    tkUl,
    tkBlock,
    tkLink,
    tkEOF,

  Token = ref object
    kind: TokenKind
    value: string

  State = enum
    startState,
    headState,
    normalState,
    blockState,
    linkState,

  Lexer = ref object
    name: string
    text: string
    currentChar: char
    state: State
    langName: string
    pos: int
    line: int
    col: int

type BlogPost = object
  title: string
  link: string
  description: string
  path: string  # For sorting by date
  pubDate: string
  dateObj: DateTime  # For sorting

proc extractMetadata(file: string): BlogPost =
  let text = readFile(file)
  var
    inHeader = false
    title = ""
    date = ""

  for line in text.splitLines():
    if line == "---":
      if inHeader:
        break
      else:
        inHeader = true
        continue

    if inHeader:
      let parts = line.split(":", 1)
      if parts.len >= 2:
        let
          key = parts[0].strip()
          value = parts[1].strip()

        if key == "title":
          title = value
        elif key == "date":
          date = value

  # Convert file path to URL path
  let urlPath = file.replace("src/blog/", "").replace(".md", "")
  let link = &"https://basswood-io.com/blog/{urlPath}"

  return BlogPost(
    title: title,
    link: link,
    description: link,  # Using link as description as seen in the example
    path: file,
    pubDate: date,
    dateObj: parseDate(date),
  )

proc generateRSSFeed(outputPath: string) =
  var posts: seq[BlogPost] = @[]

  # Collect all blog posts
  for file in walkFiles("src/blog/*.md"):
    if file.endsWith("index.md"):
      continue  # Skip index

    let post = extractMetadata(file)
    posts.add(post)

  # Sort posts by date (newest first)
  posts.sort(proc (x, y: BlogPost): int =
    # Compare dates in reverse order for newest first
    result = cmp(y.dateObj, x.dateObj)
  )

  # Generate RSS XML
  var rssContent = """<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
  <channel>
    <title>Basswood-io Blog</title>
    <link>https://basswood-io.com</link>
    <description>News from basswood-io</description>
    <language>en-us</language>
"""

  # Add items
  for post in posts:
    rssContent &= &"""    <item>
      <title>{post.title}</title>
      <link>{post.link}</link>
      <pubDate>{post.pubDate}</pubDate>
      <description>{post.description}</description>
    </item>
"""

  # Close tags
  rssContent &= "  </channel>\n</rss>"

  # Write to file
  writeFile(outputPath, rssContent)
  echo "Generated RSS feed at: ", outputPath

func initLexer(name: string, text: string): Lexer =
  return Lexer(name: name, text: text, currentChar: text[0],
               state: startState, langName: "", pos: 0, line: 1, col: 1)

proc error(self: Lexer, msg: string) =
  write(stderr, &"{self.name}:{self.line}:{self.col} {msg}")
  system.quit(1)

proc advance(self: Lexer) =
  self.pos += 1
  if self.pos > len(self.text) - 1:
    self.currentChar = '\0'
  else:
    if self.currentChar == '\n':
      self.line += 1
      self.col = 1
    else:
      self.col += 1

    self.currentChar = self.text[self.pos]

func peek(self: Lexer): char =
  let peakPos = self.pos + 1
  return (if peakPos > len(self.text) - 1: '\0' else: self.text[peakPos])

func longPeek(self: Lexer, pos: int): char =
  let peakPos = self.pos + pos
  return (if peakPos > len(self.text) - 1: '\0' else: self.text[peakPos])

func initToken(kind: TokenKind, value: string): Token =
  return Token(kind: kind, value: value)

proc getNextToken(self: Lexer): Token =
  var rod = ""
  var levels = 0
  while self.currentChar != '\0':
    if self.state == linkState:
      rod = ""
      while self.currentChar != ')':
        rod &= self.currentChar
        self.advance()
      self.advance()
      self.state = normalState
      return initToken(tkText, rod)  # return link ref
    if self.currentChar == '\n':
      self.advance()
      return initToken(tkNewline, "")

    if self.state == normalState and self.currentChar == '[':  # Handle links
      self.advance()
      rod = ""
      while self.currentChar != ']':
        rod &= self.currentChar
        self.advance()
      self.advance()
      if self.currentChar != '(':
        self.error("link expected ref")
      self.advance()
      self.state = linkState
      return initToken(tkLink, rod)

    if self.state == normalState and self.currentChar == '`':  # Handle code ticks
      while self.currentChar == '`':
        levels += 1
        self.advance()

      if levels == 1:
        rod = ""
        while self.currentChar != '`':
          rod &= self.currentChar
          self.advance()
        self.advance()

        if rod.strip() == "":
          self.error("Tick can't be blank")

        return initToken(tkTick, rod)
      elif levels == 3:
        self.state = blockState

        var langName = ""
        while not (self.currentChar in @['\n', '\0']):
          langName &= self.currentChar
          self.advance()

        self.langName = langName
        return initToken(tkBlock, "")
      elif levels != 0:
        self.error(&"Wrong number of `s, ({levels})")

    if self.state == blockState and self.currentChar == '`':
      levels = 0
      while longPeek(self, levels) == '`':
        levels += 1
        if levels == 5:
          break

      if levels == 3:
        self.advance()
        self.advance()
        self.advance()
        self.state = normalState
        return initToken(tkBlock, "")
      else:
        while levels > 0:
          levels -= 1
          rod &= '`'
          self.advance()

    rod &= self.currentChar

    if self.state == headState and self.currentChar == ':':
      self.advance()  # then go to ` `
      while self.currentChar == ' ':
        self.advance()

      rod = ""
      while self.currentChar != '\n':
        if self.currentChar == '\0':
          self.error("Got EOF on key-value pair")

        if self.currentChar != '\n':
          rod &= self.currentChar

        self.advance()

      self.advance()
      return initToken(keyval, rod)

    if self.state in @[startState, headState, normalState] and rod == "---":
      self.advance()
      self.advance()
      if self.state == startState:
        self.state = headState
      elif self.state == headState:
        self.state = normalState
      return initToken(tkBar, "")

    var breakToken = false
    if self.peek() == '\n':
      breakToken = true
    elif self.state == normalState and self.peek() == '`':
      breakToken = true
    elif self.state == normalState and self.peek() == '[':
      breakToken = true
    elif self.state == blockState and self.peek() == '#':
      breakToken = true
    elif self.state == headState and self.peek() == ':':
      breakToken = true

    if breakToken:
      self.advance()
      if rod.strip() == "":
        continue
      else:
        return initToken(tkText, rod)

    if self.state == blockState and self.currentChar == '#' and self.peek() == ' ':
      self.advance()
      return initToken(tkH1, "")  # Italicize comments

    if self.state == normalState:
      if (self.col == 1 and self.currentChar == '*' and self.peek() == ' ') or
        (self.col == 1 and self.currentChar == ' ' and self.peek() == '*'):
        self.advance()
        self.advance()
        return initToken(tkList, "")

      if self.col == 1 and self.currentChar == ' ' and self.peek() == '-':
        self.advance()
        self.advance()
        return initToken(tkUl, "")

      levels = 0
      if self.currentChar == '#' and self.col == 1:
        while self.currentChar == '#':
          levels += 1
          self.advance()

        if self.currentChar != ' ':
          self.error("Expected space after header")
        self.advance()

        if levels == 3:
          return initToken(tkH3, "")
        elif levels == 2:
          return initToken(tkH2, "")
        elif levels == 1:
          return initToken(tkH1, "")
        elif levels != 0:
          self.error("Too many #s")

    self.advance()

  return initToken(tkEOF, "")


proc convert(pragma: PragmaKind, baseUrl, lang, file, path: string) =
  let text = readFile(file)
  var
    lexer = initLexer(file, text)
    author = ""
    date = ""
    desc = ""

  if getNextToken(lexer).kind != tkBar:
    error(lexer, "Expected --- at start")

  proc parseKeyval(key: string): string =
    var token = getNextToken(lexer)
    if token.kind != tkText:
      lexer.error("head: expected text")

    if token.value != key:
      lexer.error(&"Expected {key}, got {token.value}")

    token = getNextToken(lexer)
    if token.kind != keyval:
      lexer.error("head: expected keyval")

    return token.value

  let title = parseKeyval("title")

  if pragma == blogType:
    author = parseKeyval("author")
    date = parseKeyval("date")
    desc = parseKeyval("desc")

  if getNextToken(lexer).kind != tkBar:
    lexer.error("head: expected end ---")

  let f = open(path, fmWrite)

  var reload = ""
  if paramCount() > 0 and paramStr(1) == "--dev":
    reload = """<script>var bfr = '';
  setInterval(function () {
      fetch(window.location).then((response) => {
          return response.text();
      }).then(r => {
          if (bfr != '' && bfr != r) {
              setTimeout(function() {
                  window.location.reload();
              }, 1000);
          }
          else {
              bfr = r;
          }
      });
  }, 1000);</script>"""

  f.write(&"""
<!DOCTYPE html>
<html lang="{lang}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title}</title>""")

  if desc != "no-index":
    f.write(&"""

  <meta property="og:title" content="{title}">""")

  if desc != "" and desc != "no-index":
    f.write(&"\n  <meta name=\"description\" content=\"{desc}\">")

  if desc != "no-index":
    var url = path.replace("src/", "")
    if url.endswith("/index.html"):
      url = url.replace("/index.html", "")
    else:
      url = url.replace(".html", "")
    f.write(&"""

  <link rel="canonical" href="{baseUrl}/{url}">
  <meta property="og:url" content="{baseUrl}/{url}">""")
  else:
    f.write("\n  <meta name=\"robots\" content=\"noindex\">")

  f.write(&"""

  <link rel="stylesheet" href="/style.css?v=1.0.0">
  <link media="(prefers-color-scheme: light)" rel="icon" type="image/png" href="/favicon/light.png" sizes="90x90">
  <link media="(prefers-color-scheme: dark)" rel="icon" type="image/png" href="/favicon/dark.png" sizes="90x90">{reload}
</head>
<body>
<section class="section">
<div class="container">
""")

  if pragma == blogType:
    # Format date for HTML display
    let displayDate =
      try:
        # Try to parse RFC 2822 format with timezone abbreviation
        let parsedDate = parse(date, "ddd, dd MMM yyyy HH:mm:ss zzz")
        format(parsedDate, "MMMM d, yyyy")
      except:
        # Try without timezone parsing, just use the date part
        let datePart = date.split(" ")[1..3].join(" ")  # Extract "29 Jul 2024"
        let parsedDate = parse(datePart, "dd MMM yyyy")
        format(parsedDate, "MMMM d, yyyy")

    f.write(&"""
    <h1>{title}</h1>
    <div style="display: flex; align-items: center; gap: 12px">
      <img src="/img/profile.jpg" width="30" height="30" style="border-radius: 9999px; margin-right: -6px">
      <p style="margin-block-end: 0.4em;">{author}</p>
      <p style="margin-block-end: 0.4em;">{displayDate}</p>
    </div>
""")

  let forPandoc = text[lexer.pos..^1]
  f.write(execCmdEx("pandoc --from markdown --to html5", input = forPandoc).output)

  if pragma == blogType:
    f.write("<hr><a href=\"./\">Blog Index</a>\n")
  f.write("</div>\n</section>\n</body>\n</html>\n")
  f.close()

  removeFile file

proc main =
  removeDir("public")
  copyDir("src", "public")

  let table2 = parsetoml.parseFile("hunim.toml")

  let baseUrl = $table2["baseURL"]
  let lang = $table2["languageCode"]

  generateRSSFeed("src/blog/index.xml")

  convert(normalType, baseUrl, lang, "public/blog/index.md", "public/blog/index.html")
  for file in walkFiles("public/blog/*.md"):
    convert(blogType, baseUrl, lang, file, file.changeFileExt("html"))

  processDirectory("public")
  echo "done building"

proc health =
  let pandocFound = findExe("pandoc") != ""
  let rsyncFound = findExe("rsync") != ""
  let tomlFound = fileExists("hunim.toml")

  if pandocFound:
    stdout.styledWriteLine("Can convert markdown to html ", fgGreen, "(pandoc found)")
  else:
    stdout.styledWriteLine("Can convert markdown to html ", fgRed, "(pandoc not found)")
  stdout.resetAttributes()

  if rsyncFound:
    stdout.styledWriteLine("Can upload to server ", fgGreen, "(rsync found)")
  else:
    stdout.styledWriteLine("Can upload to server ", fgRed, "(rsync not found)")
  stdout.resetAttributes()

  if tomlFound:
    stdout.styledWriteLine("hunim.toml found ", fgGreen, "(true)")
  else:
    stdout.styledWriteLine("hunim.toml found ", fgRed, "(false)")
  stdout.resetAttributes()

proc newSite(siteName: string) =
  createDir(siteName)
  setCurrentDir(siteName)

  writeFile(
    "hunim.toml",
    &"baseURL = 'https://{siteName}.com'\nlanguageCode = 'en-us'\ntitle = '{siteName}'\n"
  )

  createDir("components")
  createDir("src")
  setCurrentDir("src")
  writeFile(
    "index.html",
    &"""
<!DOCTYPE html>
<html lang="en-us">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{siteName}</title>
</head>
<body>
  <h1>Hello World!</h1>
</body>
</html>
""",
  )

when isMainModule:
  if paramCount() < 1:
    main()
  elif paramStr(1) == "version":
    echo "0.1.0"
  elif paramStr(1) == "health":
    health()
  elif paramStr(1) == "newsite":
    if paramCount() < 2:
      error "You must provide a site name"
    newSite(paramStr(2))
  else:
    error &"Unknown command: {paramStr(1)}"
