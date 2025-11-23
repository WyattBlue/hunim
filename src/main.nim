import std/[algorithm, sequtils, strformat, strutils, terminal, times, os,
    osproc, tables]
import std/[asynchttpserver, asyncdispatch, uri]

import parsetoml
import markdown


method `$`*(token: Heading): string =
  let num = $token.level
  let child = token.render("")
  if num == "1" or num == "2":
    let id = child.toLower.replace(" ", "-")
    fmt"""<h{num} id="{id}">{child}</h{num}>"""
  else:
    fmt"<h{num}>{child}</h{num}>"

# Global caches for templates and components
var templateCache = initTable[string, string]()
var componentCache = initTable[string, string]()
var buildDrafts = false

proc ctrlc() {.noconv.} =
  echo ""
  quit(1)

setControlCHook(ctrlc)

proc error(msg: string) =
  stderr.styledWriteLine(fgRed, bgBlack, msg, resetStyle)
  quit(1)

proc loadComponents() =
  ## Load all components from the components directory into cache
  componentCache.clear()
  if not dirExists("components"):
    return

  for kind, comp in walkDir("components"):
    let compName = comp.extractFilename().changeFileExt("")
    if kind == pcFile and not compName.startsWith("."):
      componentCache[compName] = readFile(comp).strip()

proc loadTemplates() =
  ## Load all templates from the templates directory into cache
  templateCache.clear()
  if not dirExists("templates"):
    return

  for kind, tmpl in walkDir("templates"):
    let tmplName = tmpl.extractFilename()
    if kind == pcFile and not tmplName.startsWith("."):
      templateCache[tmplName] = readFile(tmpl)

proc parseDate(date: string): DateTime =
  # Parse RFC 2822 dates

  let explode = rsplit(date, " ", 1)
  let date2 = explode[0]
  let timezone = explode[1]

  result = parse(date2, "ddd, dd MMM yyyy HH:mm:ss")
  case timezone:
    of "EDT": result -= initDuration(hours = -4)
    of "EST": result -= initDuration(hours = -5)
    of "CDT": result -= initDuration(hours = -5)
    of "CST": result -= initDuration(hours = -6)
    of "MDT": result -= initDuration(hours = -6)
    of "MST": result -= initDuration(hours = -7)
    of "PDT": result -= initDuration(hours = -7)
    of "PST": result -= initDuration(hours = -8)
    of "AKDT": result -= initDuration(hours = -8)
    of "AKST": result -= initDuration(hours = -9)
    of "HST": result -= initDuration(hours = -10)
    of "UTC": discard
    else: error &"Unknown time zone: {timezone}"

  return result


func shouldProcessFile(path: string): bool =
  if path.endsWith(".DS_Store"):
    return false

  let ext = path.splitFile().ext.toLowerAscii()
  return ext notin [".avif", ".webp", ".png", ".jpeg", ".jpg", ".svg"]

proc parseTemplate(content: string, compName: string,
    compContent: string): string =
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

proc renderTemplate(templateContent: string, context: Table[string,
    string]): string =
  # Renders a Go-style template by replacing {{ .Key }} with context values
  result = templateContent
  for key, value in context:
    result = result.replace("{{ ." & key & " }}", value)
  return result

proc processFile(path: string, baseUrl: string): string =
  # Skip non-HTML files
  let ext = path.splitFile().ext.toLowerAscii()
  if ext != ".html":
    return ""

  if not shouldProcessFile(path):
    return ""

  var content = readFile(path)

  # Use cached components instead of reading from disk
  for compName, compContent in componentCache:
    content = parseTemplate(content, compName, compContent)

  var outputPath = path
  var wasRenamed = false
  if path.endsWith("index.html"):
    outputPath = path
  elif path.endsWith(".html"):
    outputPath = path.splitFile().dir / path.splitFile().name
    wasRenamed = true

  writeFile(outputPath, content)

  if outputPath != path:
    removeFile(path)
  #   echo "Processed and renamed: ", path, " -> ", outputPath
  # else:
  #   echo "Processed: ", path

  # Only add to sitemap if this is an index.html file
  # Non-index HTML files that get renamed were generated from markdown
  # and already added to sitemap during conversion
  if wasRenamed:
    return ""

  # Check if page has noindex meta tag
  if content.contains("<meta name=\"robots\" content=\"noindex\">"):
    return ""

  # Generate URL for sitemap
  var url = outputPath.replace("public/", "")
  if url.endsWith("/index.html"):
    url = url.replace("/index.html", "")
  elif url == "index.html":
    url = ""
  elif url.endsWith(".html"):
    url = url[0..^6] # Remove .html extension

  return baseUrl & url

proc processDirectory(dir: string, baseUrl: string, urls: var seq[string]) =
  for kind, path in walkDir(dir):
    if kind == pcFile:
      let url = processFile(path, baseUrl)
      if url != "":
        urls.add(url)
    elif kind == pcDir:
      processDirectory(path, baseUrl, urls)

type

  TokenKind = enum
    tkBar,
    keyval,
    tkText,
    tkNewline,
    tkEOF,

  Token = ref object
    kind: TokenKind
    value: string

  State = enum
    startState,
    headState,
    finalState,

  Lexer = ref object
    name: string
    text: string
    currentChar: char
    state: State
    pos: int
    line: int
    col: int

type BlogPost = object
  title: string
  link: string
  path: string      # For sorting by date
  pubDate: string
  dateObj: DateTime # For sorting

proc extractMetadata(baseUrl, file: string): BlogPost =
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
  assert file.startsWith("public/")

  let urlPath = file[7..<file.len].changeFileExt("")
  let link = &"{baseUrl}{urlPath}"

  return BlogPost(
    title: title,
    link: link,
    path: file,
    pubDate: date,
    dateObj: parseDate(date),
  )

func initLexer(name, text: string): Lexer =
  Lexer(name: name, text: text, currentChar: text[0], state: startState,
      line: 1, col: 1)

proc error(self: Lexer, msg: string) =
  stderr.writeLine(&"{self.name}:{self.line}:{self.col} {msg}")
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

func initToken(kind: TokenKind, value: string): Token =
  return Token(kind: kind, value: value)

proc getNextToken(self: Lexer): Token =
  var rod = ""
  while self.currentChar != '\0':
    if self.currentChar == '\n':
      self.advance()
      return initToken(tkNewline, "")

    rod &= self.currentChar

    if self.state == headState and self.currentChar == ':':
      self.advance() # then go to ` `
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

    if rod == "---":
      self.advance()
      self.advance()
      if self.state == startState:
        self.state = headState
      elif self.state == headState:
        self.state = finalState
      return initToken(tkBar, "")

    if self.peek() == '\n' or (self.state == headState and self.peek() == ':'):
      self.advance()
      if rod.strip() == "":
        continue
      else:
        return initToken(tkText, rod)

    self.advance()

  return initToken(tkEOF, "")

proc parseFrontmatter(file: string): Table[string, string] =
  let text = readFile(file)
  var lexer = initLexer(file, text)

  if getNextToken(lexer).kind != tkBar:
    lexer.error("Expected --- at start")

  var token = getNextToken(lexer)
  while token.kind != tkBar:
    if token.kind == tkText:
      let key = token.value
      token = getNextToken(lexer)
      if token.kind != keyval:
        lexer.error("frontmatter: Expected key value pair")
      result[key] = token.value
      token = getNextToken(lexer)
    elif token.kind != tkBar:
      lexer.error("frontmatter: Expected --- at the end")

proc nonFrontmatter(file: string): string =
  let text = readFile(file)
  var lexer = initLexer(file, text)

  if getNextToken(lexer).kind != tkBar:
    lexer.error("Expected --- at start")

  var token = getNextToken(lexer)
  while token.kind != tkBar:
    if token.kind == tkText:
      token = getNextToken(lexer)
      if token.kind != keyval:
        lexer.error("frontmatter: Expected key value pair")
      token = getNextToken(lexer)
    elif token.kind != tkBar:
      lexer.error("frontmatter: Expected --- at the end")

  return text[lexer.pos..^1]

proc generateRSSFeed(frontmatter: Table[string, string], lang, baseUrl,
    inputPath, outputPath: string) =
  var posts: seq[BlogPost] = @[]

  # Collect all blog posts
  for file in walkFiles(inputPath / "*.md"):
    if file.endsWith("index.md"):
      continue

    if not buildDrafts:
      let fileFrontmatter = parseFrontmatter(file)
      if fileFrontmatter.getOrDefault("draft", "false") == "true":
        continue

    let post = extractMetadata(baseUrl, file)
    posts.add(post)

  # Sort posts by date (newest first)
  posts.sort(proc (x, y: BlogPost): int =
    # Compare dates in reverse order for newest first
    result = cmp(y.dateObj, x.dateObj)
  )

  let title = frontmatter.getOrDefault("title", "RSS Feed")
  let desc = frontmatter.getOrDefault("desc", "My RSS Feed")

  # Generate RSS XML
  var rssContent = &"""<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
  <channel>
    <title>{title}</title>
    <link>{baseUrl}</link>
    <description>{desc}</description>
    <language>{lang}</language>
"""

  # Add items
  for post in posts:
    rssContent &= &"""    <item>
      <title>{post.title}</title>
      <link>{post.link}</link>
      <pubDate>{post.pubDate}</pubDate>
      <description>{post.link}</description>
    </item>
"""

  # Close tags
  rssContent &= "  </channel>\n</rss>"

  # Write to file
  writeFile(outputPath, rssContent)
  echo "Generated RSS feed at: ", outputPath

proc writeSitemap(urls: seq[string], outputPath: string) =
  # Generate sitemap XML
  var sitemapContent = """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
"""

  for url in urls:
    sitemapContent &= &"""  <url>
    <loc>{url}</loc>
  </url>
"""

  sitemapContent &= "</urlset>"

  # Write to file
  writeFile(outputPath, sitemapContent)
  echo "Generated sitemap at: ", outputPath


type ConvertJob = object
  doReload: bool
  baseUrl: string
  lang: string
  file: string
  path: string
  feedDir: string

proc processConvertedMarkdown(job: ConvertJob, htmlOutput: string): string =
  let frontmatter = parseFrontmatter(job.file)
  var templateFile = ""

  # Get template from the frontmatter, or use implicit template for feed posts
  if job.feedDir != "":
    # Extract directory name from feedDir (e.g., "public/myblog" -> "myblog")
    let dirName = job.feedDir.split('/')[^1]
    let implicitTemplate = dirName & "_list.html"
    let implicitTemplatePath = "templates" / implicitTemplate

    if fileExists(implicitTemplatePath):
      templateFile = implicitTemplate
    else:
      templateFile = frontmatter.getOrDefault("template", "default.html")
  else:
    templateFile = frontmatter.getOrDefault("template", "default.html")

  let desc = frontmatter.getOrDefault("desc", "")

  # Check if template file exists
  let templatePath = "templates" / templateFile
  let useTemplate = fileExists(templatePath)

  var reload = ""
  if job.doReload:
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

  var htmlContent = htmlOutput

  # Fix relative links in index pages to use correct directory path
  if job.path.endsWith("/index.html"):
    let dir = job.path.replace("public/", "/").replace("/index.html", "/")
    htmlContent = htmlContent.replace("href=\"./", "href=\"" & dir)

  # Prepare content for rendering
  var content = htmlContent

  # Prepare meta tags
  var metaTags = ""
  if desc != "no-index" and frontmatter.hasKey("title"):
    let title = frontmatter["title"]
    metaTags &= &"\n  <meta property=\"og:title\" content=\"{title}\">"

  if desc != "" and desc != "no-index":
    metaTags &= &"\n  <meta name=\"description\" content=\"{desc}\">"

  var sitemapUrl = ""
  if desc != "no-index":
    var url = job.path.replace("public/", "")
    if url.endswith("/index.html"):
      url = url.replace("/index.html", "")
    else:
      url = url.replace(".html", "")
    metaTags &= &"\n  <link rel=\"canonical\" href=\"{job.baseUrl}{url}\">"
    metaTags &= &"\n  <meta property=\"og:url\" content=\"{job.baseUrl}{url}\">"
    sitemapUrl = job.baseUrl & url
  else:
    metaTags &= "\n  <meta name=\"robots\" content=\"noindex\">"

  let f = open(job.path, fmWrite)

  if useTemplate:
    # Use cached template instead of reading from disk
    if not templateCache.hasKey(templateFile):
      error &"Template file not found in cache: {templateFile}"
    let templateContent = templateCache[templateFile]
    var context = initTable[string, string]()
    if frontmatter.hasKey("title"):
      context["Title"] = frontmatter["title"]
    if job.feedDir != "" and frontmatter.hasKey("date"):
      let date = frontmatter["date"]
      let displayDate =
        try:
          # Try to parse RFC 2822 format with timezone abbreviation
          let parsedDate = parse(date, "ddd, dd MMM yyyy HH:mm:ss zzz")
          format(parsedDate, "MMMM d, yyyy")
        except:
          # Try without timezone parsing, just use the date part
          let datePart = date.split(" ")[1..3].join(" ") # Extract "29 Jul 2024"
          let parsedDate = parse(datePart, "dd MMM yyyy")
          format(parsedDate, "MMMM d, yyyy")
      context["Date"] = displayDate
      if frontmatter.hasKey("author"):
        context["Author"] = frontmatter["author"]

    context["Content"] = content
    context["Lang"] = job.lang
    context["MetaTags"] = metaTags
    context["Reload"] = reload

    let renderedHtml = renderTemplate(templateContent, context)
    f.write(renderedHtml)
  else:
    error "Expected template file"

  f.close()
  removeFile(job.file)

  return sitemapUrl

proc main =
  try:
    removeDir("public")
  except Exception:
    discard
  try:
    copyDir("src", "public")
  except Exception:
    error "Expected a src directory"

  # Load templates and components into cache at startup
  loadTemplates()
  loadComponents()

  let table2 = parsetoml.parseFile("hunim.toml")

  let baseUrl = $table2["baseURL"]
  if not baseUrl.endsWith("/"):
    error "baseURL must end with /"

  let lang = $table2["languageCode"]

  let doReload = paramCount() > 0 and paramStr(1) == "--dev"

  var sitemapUrls: seq[string] = @[]

  proc collectJobs(dir: string, isFeed: bool, jobs: var seq[ConvertJob]) =
    ## Recursively collect all markdown conversion jobs
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".md"):
        # Check if the file is a draft and should be skipped
        if not buildDrafts:
          let frontmatter = parseFrontmatter(path)
          if frontmatter.getOrDefault("draft", "false") == "true":
            continue

        let feedDir = (if isFeed and not path.endsWith(
            "index.md"): dir else: "")
        jobs.add(ConvertJob(
          doReload: doReload,
          baseUrl: baseUrl,
          lang: lang,
          file: path,
          path: path.changeFileExt("html"),
          feedDir: feedDir
        ))
      elif kind == pcDir:
        let indexFile = path / "index.md"
        var isFeed2 = false
        if fileExists(indexFile):
          let frontmatter = parseFrontmatter(indexFile)
          if frontmatter.hasKey("type") and frontmatter["type"] == "feed":
            isFeed2 = true
            generateRSSFeed(frontmatter, lang, baseUrl, path, path / "index.xml")
        collectJobs(path, isFeed2, jobs)

  var jobs: seq[ConvertJob] = @[]
  collectJobs("public", false, jobs)

  # Convert all markdown files with parallel Pandoc execution
  echo &"Converting {jobs.len} markdown files in parallel..."

  # Start all Pandoc processes at once using temp files
  type PandocTask = object
    process: Process
    job: ConvertJob
    inputFile: string
    outputFile: string

  var tasks: seq[PandocTask] = @[]
  let tmpDir = getTempDir() / "hunim_" & $getCurrentProcessId()
  createDir(tmpDir)

  for i, job in jobs:
    let frontmatter = parseFrontmatter(job.file)
    let renderer = frontmatter.getOrDefault("renderer", "")

    # Write markdown to temp file
    let inputFile = tmpDir / &"input_{i}.md"
    let outputFile = tmpDir / &"output_{i}.html"
    let mdContent = nonFrontmatter(job.file)
    writeFile(inputFile, mdContent)

    var p: Process
    if renderer == "pandoc":
      # Start Pandoc process (non-blocking)
      p = startProcess(
        "pandoc",
        args = ["--from", "markdown", "--to", "html5", "-o", outputFile,
            inputFile],
        options = {poUsePath}
      )
    else:
      let htmlOutput = markdown(mdContent)
      writeFile(outputFile, htmlOutput)
      # Create a dummy process that has already exited
      p = nil

    tasks.add(PandocTask(
      process: p,
      job: job,
      inputFile: inputFile,
      outputFile: outputFile
    ))

  # Wait for all processes to complete and collect results
  for task in tasks:
    if task.process != nil:
      let exitCode = task.process.waitForExit()
      task.process.close()

      if exitCode != 0:
        error &"Pandoc failed for file {task.job.file}"

    # Read the output
    let htmlOutput = readFile(task.outputFile)

    # Clean up temp files
    removeFile(task.inputFile)
    removeFile(task.outputFile)

    # Now do the rest of the conversion synchronously
    let url = processConvertedMarkdown(task.job, htmlOutput)
    if url != "":
      sitemapUrls.add(url)

  # Clean up temp directory
  removeDir(tmpDir)
  processDirectory("public", baseUrl, sitemapUrls) # Handle components
  writeSitemap(sitemapUrls, "public/sitemap.xml") # Generate sitemap
  echo "done building"

proc health =
  let pandocFound = findExe("pandoc") != ""
  let rsyncFound = findExe("rsync") != ""
  let tomlFound = fileExists("hunim.toml")

  stdout.styledWriteLine("Can convert html/components to html ", fgGreen, "(yes)")
  stdout.resetAttributes()
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
    &"baseURL = 'https://{siteName}.com/'\nlanguageCode = 'en-us'\ntitle = '{siteName}'\n"
  )

  createDir("components")
  createDir("templates")
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

proc getMimeType(filename: string): string =
  let ext = splitFile(filename).ext.toLowerAscii()
  case ext
  of ".html", ".htm":
    return "text/html; charset=utf-8"
  of ".css":
    return "text/css; charset=utf-8"
  of ".js":
    return "application/javascript; charset=utf-8"
  of ".json":
    return "application/json; charset=utf-8"
  of ".xml":
    return "application/xml; charset=utf-8"
  of ".png":
    return "image/png"
  of ".jpg", ".jpeg":
    return "image/jpeg"
  of ".gif":
    return "image/gif"
  of ".svg":
    return "image/svg+xml"
  of ".webp":
    return "image/webp"
  of ".avif":
    return "image/avif"
  of ".ttf":
    return "font/ttf"
  of ".pdf":
    return "application/pdf"
  of "":
    if fileExists(filename):
      try:
        let content = readFile(filename)
        if content.startsWith("<!DOCTYPE html") or content.startsWith("<html"):
          return "text/html; charset=utf-8"
      except:
        discard
    return "application/octet-stream"
  else:
    return "application/octet-stream"

proc serveFile(path: string): tuple[code: HttpCode, content: string,
    mimeType: string] =
  if not fileExists(path):
    return (Http404, "404 Not Found", "text/plain")

  try:
    let content = readFile(path)
    let mimeType = getMimeType(path)
    return (Http200, content, mimeType)
  except IOError:
    return (Http500, "500 Internal Server Error", "text/plain")

proc getLastModTime(dir: string): Time =
  var lastMod = fromUnix(0)
  if not dirExists(dir):
    return lastMod

  for kind, path in walkDir(dir):
    if kind == pcFile:
      let info = getFileInfo(path)
      if info.lastWriteTime > lastMod:
        lastMod = info.lastWriteTime
    elif kind == pcDir:
      let subdirMod = getLastModTime(path)
      if subdirMod > lastMod:
        lastMod = subdirMod

  return lastMod

proc rebuild =
  stdout.styledWriteLine(fgCyan, "Rebuilding site...")
  stdout.resetAttributes()
  try:
    main()
  except:
    stderr.styledWriteLine(fgRed, "Build failed: " & getCurrentExceptionMsg())
    stderr.resetAttributes()

proc server(watchMode: bool) =
  let port = 8080
  let address = "127.0.0.1"

  var httpServer = newAsyncHttpServer()
  var lastModTime = getLastModTime("src")

  proc handleRequest(req: Request) {.async.} =
    var path = req.url.path.decodeUrl()

    # Normalize path
    if path == "" or path == "/":
      path = "/index.html"

    # Security: prevent directory traversal
    if path.contains(".."):
      await req.respond(Http403, "403 Forbidden")
      return

    # Build full file path
    let filePath = "public" & path

    # If path is a directory, try to serve index.html
    if dirExists(filePath):
      let indexPath = filePath / "index.html"
      let (code, content, mimeType) = serveFile(indexPath)
      await req.respond(code, content, newHttpHeaders([("Content-Type", mimeType)]))
    else:
      let (code, content, mimeType) = serveFile(filePath)
      await req.respond(code, content, newHttpHeaders([("Content-Type", mimeType)]))

    echo &"{req.reqMethod} {req.url.path} -> {filePath}"

  proc checkForChanges {.async.} =
    while true:
      await sleepAsync(1000) # Check every second
      let currentModTime = getLastModTime("src")
      if currentModTime > lastModTime:
        lastModTime = currentModTime
        rebuild()

  stdout.styledWriteLine(fgGreen, &"Server running at http://{address}:{port}/")
  if watchMode:
    stdout.styledWriteLine(fgCyan, "Watching for file changes...")
  stdout.styledWriteLine(fgYellow, "Press Ctrl+C to stop")
  stdout.resetAttributes()

  if watchMode:
    asyncCheck checkForChanges()

  waitFor httpServer.serve(Port(port), handleRequest, address)

when isMainModule:
  var cmd = ""
  var cmd2 = ""
  var watchMode = false
  # Parse --buildDrafts or -D option from any parameter position
  for i in 1..paramCount():
    if paramStr(i) == "--buildDrafts" or paramStr(i) == "-D":
      buildDrafts = true
      break
    elif paramStr(i) == "--watch":
      watchMode = true
    elif not paramStr(i).startsWith("-") and cmd == "":
      cmd = paramStr(i)
    elif cmd2 == "":
      cmd2 = paramStr(i)

  if cmd == "":
    main()
  elif cmd == "version":
    echo "0.1.0"
  elif cmd == "health":
    health()
  elif cmd == "newsite":
    if cmd2 == "":
      error "You must provide a site name"
    newSite(cmd2)
  elif cmd == "server":
    rebuild()
    server(watchMode)
  else:
    error &"Unknown command: {cmd}"
