#!/usr/bin/env python3
"""Build a small offline grammar and theme bundle for a fresh installation.

Installed TextMate bundles take precedence over this bundle. These grammars only
provide basic highlighting until the full language bundles are installed.
"""

import plistlib
import re
import sys
import uuid
from pathlib import Path


BUNDLE_ID = uuid.UUID("b6c41665-6233-49ac-a66c-1934ba2c730a")


def identifier(name):
    return str(uuid.uuid5(BUNDLE_ID, name)).upper()


def match(pattern, scope):
    return {"match": pattern, "name": scope}


def region(begin, end, scope, patterns=()):
    return {"begin": begin, "end": end, "name": scope, "patterns": list(patterns)}


def language(name, scope, extensions, keywords=(), comments=(), strings=True, extra=(), first_line=None):
    patterns = list(comments)
    if strings:
        patterns += [region('"', '(?<!\\\\)"', "string.quoted.double"),
                     region("'", "(?<!\\\\)'", "string.quoted.single")]
    patterns += list(extra)
    if keywords:
        patterns.append(match(r"\b(?:" + "|".join(map(re.escape, keywords)) + r")\b", "keyword.control"))
    patterns.append(match(r"\b(?:true|false|null|nil|None|True|False|undefined)\b", "constant.language"))
    patterns.append(match(r"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b", "constant.numeric"))
    result = {"name": name, "scopeName": scope, "fileTypes": extensions,
              "patterns": patterns, "uuid": identifier(scope)}
    if first_line:
        result["firstLineMatch"] = first_line
    return result


HASH = [match(r"#.*$", "comment.line.number-sign")]
SLASH = [match(r"//.*$", "comment.line.double-slash"),
         region(r"/\*", r"\*/", "comment.block")]

GRAMMARS = [
    language("Python", "source.python", ["py", "pyw"],
             "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield".split(),
             HASH, first_line=r"^#!.*\bpython(?:\d+(?:\.\d+)?)?\b"),
    language("Swift", "source.swift", ["swift"],
             "actor as async await break case catch class continue default defer do else enum extension fallthrough for func guard if import in init let nil operator private protocol public repeat return self static struct subscript switch throw throws try typealias var where while".split(), SLASH),
    language("JavaScript", "source.js", ["js", "mjs", "cjs", "jsx"],
             "async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while yield".split(), SLASH,
             extra=[region("`", "(?<!\\\\)`", "string.quoted.template")]),
    language("TypeScript", "source.ts", ["ts", "tsx", "mts", "cts"],
             "abstract as async await break case catch class const constructor continue declare default do else enum export extends finally for from function if implements import in interface keyof let module namespace new of private protected public readonly return static switch this throw try type typeof var void while yield".split(), SLASH,
             extra=[region("`", "(?<!\\\\)`", "string.quoted.template")]),
    language("JSON", "source.json", ["json", "jsonc", "jsonl", "geojson"],
             strings=False, extra=[region('"', '(?<!\\\\)"', "string.quoted.double")]),
    language("Shell Script", "source.shell", ["sh", "bash", "zsh", "ksh"],
             "case do done elif else esac export fi for function if in local readonly return select then until while".split(),
             HASH, extra=[match(r"\$\{?[A-Za-z_][A-Za-z_0-9]*\}?", "variable.other")],
             first_line=r"^#!.*\b(?:ba|z|k)?sh\b"),
    language("C", "source.c", ["c", "h"],
             "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while".split(),
             SLASH, extra=[match(r"^\s*#\s*\w+", "keyword.control.import")]),
    language("C++", "source.c++", ["cc", "cpp", "cxx", "hpp", "hh", "hxx"],
             "auto bool break case catch class const constexpr continue default delete do double else enum explicit extern false float for friend if inline int long namespace new nullptr operator override private protected public return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while".split(),
             SLASH, extra=[match(r"^\s*#\s*\w+", "keyword.control.import")]),
    language("Objective-C", "source.objc", ["m", "mm"],
             "auto break case char const continue default do double else enum extern float for id if int long nil return self short static struct super switch typedef void while".split(),
             SLASH, extra=[match(r"@(?:interface|implementation|protocol|end|property|synthesize|selector|class|import)\b", "keyword.control"),
                           match(r"^\s*#\s*\w+", "keyword.control.import")]),
    language("Go", "source.go", ["go"],
             "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var".split(), SLASH),
    language("Rust", "source.rust", ["rs"],
             "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while".split(), SLASH),
    language("CSS", "source.css", ["css", "scss", "less"],
             comments=[region(r"/\*", r"\*/", "comment.block")],
             extra=[match(r"#[0-9a-fA-F]{3,8}\b", "constant.other.color"),
                    match(r"[-a-zA-Z]+(?=\s*:)", "support.type.property-name")]),
    language("HTML", "text.html.basic", ["html", "htm"], strings=False,
             comments=[region(r"<!--", r"-->", "comment.block")],
             extra=[match(r"</?[A-Za-z][\w:-]*", "entity.name.tag"),
                    match(r"\b[\w:-]+(?=\s*=)", "entity.other.attribute-name"),
                    region('"', '(?<!\\\\)"', "string.quoted.double"),
                    region("'", "(?<!\\\\)'", "string.quoted.single")]),
    language("Markdown", "text.html.markdown", ["md", "markdown", "mdown"], strings=False,
             extra=[match(r"^\s{0,3}#{1,6}\s+.*$", "markup.heading"),
                    match(r"^\s*>.*$", "markup.quote"),
                    region(r"```", r"```", "markup.raw.block"),
                    region(r"`", r"`", "markup.raw.inline"),
                    match(r"\*\*[^*]+\*\*", "markup.bold"),
                    match(r"\[[^]]+\]\([^)]+\)", "markup.underline.link")]),
    language("YAML", "source.yaml", ["yaml", "yml"], comments=HASH,
             extra=[match(r"[\w.-]+(?=\s*:)", "entity.name.tag"),
                    match(r"^\s*-\s", "keyword.operator")]),
    language("Plain Text", "text.plain", ["txt", "text", "log"], strings=False),
]


def theme(name, theme_id, dark):
    colors = ({"background": "#1E1E24", "foreground": "#E1E1E8", "caret": "#FFFFFF", "selection": "#41465A"}
              if dark else {"background": "#FFFFFF", "foreground": "#202124", "caret": "#202124", "selection": "#C8D9FC"})
    palette = ({"comment": "#8B9A88", "string": "#B8D989", "keyword, storage": "#C792EA",
                "constant": "#F6B773", "entity.name, support.type": "#82B9F7", "variable": "#A6D8EA",
                "markup.heading": "#A6CBFF", "markup.bold": "#E1E1E8"}
               if dark else {"comment": "#668166", "string": "#26723E", "keyword, storage": "#6545B0",
                "constant": "#99511B", "entity.name, support.type": "#135AA4", "variable": "#207A88",
                "markup.heading": "#135AA4", "markup.bold": "#202124"})
    return {"name": name, "uuid": theme_id, "settings":
            [{"settings": colors}] + [{"scope": scope, "settings": {"foreground": color}}
                                       for scope, color in palette.items()]}


def write_plist(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as file:
        plistlib.dump(data, file, sort_keys=False)


def main(destination):
    bundle = destination / "Bundles" / "Built-in.tmbundle"
    write_plist(bundle / "info.plist", {"name": "Built-in Syntaxes", "uuid": str(BUNDLE_ID).upper()})
    for grammar in GRAMMARS:
        write_plist(bundle / "Syntaxes" / (grammar["name"] + ".tmLanguage"), grammar)
    write_plist(bundle / "Themes" / "Built-in Light.tmTheme",
                theme("Built-in Light", "71D40D9D-AE48-11D9-920A-000D93589AF6", False))
    write_plist(bundle / "Themes" / "Built-in Dark.tmTheme",
                theme("Built-in Dark", "766026CB-703D-4610-B070-8DE07D967C5F", True))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
