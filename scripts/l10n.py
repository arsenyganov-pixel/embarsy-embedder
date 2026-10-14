#!/usr/bin/env python3
"""Interface translations for Embarsy.

  scripts/l10n.py extract   — compile the app's sources with the compiler's string extraction
                              and write the list of keys (English text) to Localization/source/keys.json
  scripts/l10n.py build     — write <lang>.lproj/Localizable.strings and .stringsdict from
                              Localization/source/<lang>.json; fails if a key has no translation

<lang>.json maps an English key to its translation. A plural key maps to an object of forms
({"one": …, "few": …, "many": …, "other": …}) with %lld where the number goes.
"""
import glob, json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "native", "EmbarsyApp")
LOC = os.path.join(APP, "Localization")
SRC = os.path.join(LOC, "source")


def extract():
    out = tempfile.mkdtemp(prefix="embarsy-l10n-")
    obj = tempfile.mkdtemp(prefix="embarsy-l10n-obj-")
    sources = sorted(glob.glob(os.path.join(APP, "Sources", "*.swift")))
    cmd = ["swiftc", "-target", "arm64-apple-macos13", "-parse-as-library", "-module-name", "EmbarsyApp",
           "-emit-localized-strings", "-emit-localized-strings-path", out, "-c"] + sources
    r = subprocess.run(cmd, cwd=obj, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("compile failed:\n" + "\n".join(l for l in r.stderr.splitlines() if "error" in l)[:4000])
    keys = {}
    for f in sorted(glob.glob(os.path.join(out, "*.stringsdata"))):
        d = json.load(open(f))
        for e in d["tables"].get("Localizable", []):
            keys.setdefault(e["key"], set()).add(os.path.basename(d["source"]))
    os.makedirs(SRC, exist_ok=True)
    json.dump({k: sorted(v) for k, v in sorted(keys.items())}, open(os.path.join(SRC, "keys.json"), "w"), ensure_ascii=False, indent=1)
    print(f"{len(keys)} keys → Localization/source/keys.json")


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def plist_string(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build():
    keys = json.load(open(os.path.join(SRC, "keys.json")))
    langs = [os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(SRC, "*.json")) if not p.endswith("keys.json")]
    failed = False
    for lang in langs:
        tr = json.load(open(os.path.join(SRC, lang + ".json")))
        # English is the code itself; en.json only adds plural forms ("1 issue" / "3 issues").
        missing = [] if lang == "en" else [k for k in keys if k not in tr]
        stale = [k for k in tr if k not in keys]
        if missing:
            failed = True
            print(f"{lang}: {len(missing)} keys without translation:")
            for k in missing[:40]: print("   ", k)
        if stale: print(f"{lang}: {len(stale)} translations for keys no longer in code (ignored)")
        d = os.path.join(LOC, lang + ".lproj"); os.makedirs(d, exist_ok=True)
        plain = {k: v for k, v in tr.items() if k in keys and isinstance(v, str)}
        plural = {k: v for k, v in tr.items() if k in keys and isinstance(v, dict)}
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
            for k in sorted(plain): f.write(f'"{esc(k)}" = "{esc(plain[k])}";\n')
        with open(os.path.join(d, "Localizable.stringsdict"), "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n')
            for k in sorted(plural):
                forms = plural[k]
                # One counted word: {"format", "one", "few", …} with the variable named n.
                # Several: {"format", "vars": {"a": {"one": …}, "b": {…}}}.
                variables = forms.get("vars") or {"n": {f: v for f, v in forms.items() if f not in ("format", "spec")}}
                f.write(f"  <key>{plist_string(k)}</key>\n  <dict>\n    <key>NSStringLocalizedFormatKey</key>\n    <string>{plist_string(forms['format'])}</string>\n")
                for name, rule in variables.items():
                    spec = rule.get("spec", forms.get("spec", "lld"))
                    f.write(f"    <key>{name}</key>\n    <dict>\n      <key>NSStringFormatSpecTypeKey</key>\n      <string>NSStringPluralRuleType</string>\n      <key>NSStringFormatValueTypeKey</key>\n      <string>{spec}</string>\n")
                    for form in ("zero", "one", "two", "few", "many", "other"):
                        if form in rule: f.write(f"      <key>{form}</key>\n      <string>{plist_string(rule[form])}</string>\n")
                    f.write("    </dict>\n")
                f.write("  </dict>\n")
            f.write("</dict>\n</plist>\n")
        print(f"{lang}: {len(plain)} strings, {len(plural)} plurals → {lang}.lproj")
    if failed: sys.exit(1)


if __name__ == "__main__":
    {"extract": extract, "build": build}[sys.argv[1] if len(sys.argv) > 1 else "build"]()
