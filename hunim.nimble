# Package
version       = "0.1.0"
author        = "WyattBlue"
description   = "Awesome static site generator for humans"
license       = "Unlicense"
srcDir        = "src"
bin           = @["main=hunim"]


# Dependencies
requires "nim >= 2.2.0"
requires "parsetoml"
requires "markdown"

task make, "Export the project":
  exec "nim c -d:danger --opt:size --out:hunim src/main.nim"
  when defined(macosx):
    exec "strip -ur hunim"
    exec "stat -f \"%z bytes\" ./hunim"
    echo ""
  when defined(linux):
    exec "strip -s hunim"

task bin, "Put binary in ~/bin/":
  exec "cp hunim ~/bin/"
  echo "Put hunim in ~/bin/"
