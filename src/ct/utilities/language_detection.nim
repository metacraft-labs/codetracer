import std/[os, strutils],
  ../../common/lang

# detect the lang of the source for a binary
#   based on folder/filename/files and if not possible on symbol patterns
#   in the binary
#   for scripting languages on the extension
#   for folders, we search for now for a special file
#   like `Nargo.toml`
#   just analyzing debug info might be best
#   TODO: a project can have sources in multiple languages
#   so the assumption it has a single one is not always valid
#   but for now are not reforming that yet
proc detectFolderLang(folder: string): Lang =
  if fileExists(folder / "Nargo.toml"):
    LangNoir
  else:
    # TODO: rust/ruby/others?
    LangUnknown


proc detectLang*(program: string, lang: Lang): Lang =
  # echo "detectLang ", program
  if lang == LangUnknown:
    if program.endsWith(".rb"):
      LangRubyDb
    elif program.endsWith(".nr"):
      LangNoir
    elif program.endsWith(".small"):
      LangSmall
    elif dirExists(program):
      detectFolderLang(program)
    else:
      LangUnknown
      # TODO: integrate with rr/gdb backend
  else:
    lang
