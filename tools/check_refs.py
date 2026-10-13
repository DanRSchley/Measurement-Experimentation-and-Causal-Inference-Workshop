#!/usr/bin/env python3
"""Cross-reference checker / renumberer for the workshop book.

Run from anywhere:   python tools/check_refs.py          # report problems (exit 1 if any)
                     python tools/check_refs.py --fix    # also renumber titles in place

THE MODEL
  * Module numbers = order of the `- part:` entries in _quarto.yml.
  * Part numbers   = order of chapters inside a module (the first chapter is the intro, "Part 0").
  * Prose never contains typed numbers: write  {{< ref sec-exclusion >}}  (see xref.lua).
  * The only typed numbers left are the ones Quarto reads BEFORE filters run:
        - `part: "Module 2: ..."` in _quarto.yml            (sidebar section names)
        - `title: "Part 4: ..."` in each chapter's front matter (sidebar / page title)
        - the `# Part 4: ...` heading and the iframe `title="Module 2 Part 4: ..."` attribute
    This script checks them against the chapter order and --fix rewrites them.

WHAT IT CHECKS
  1. numbering of the typed spots above
  2. every chapter has an `xref:` label; no duplicate heading ids across chapters
  3. every {{< ref ID >}} resolves to a heading id or an `xref:` label
  4. leftover hard-coded "Part N" / "Module N" / "Section N" / "Case N" in prose
     (append  <!-- xref-ok -->  to a line to silence a deliberate one; headings that start
     "Case N" / "Section N" are treated as labels local to one part and are not flagged)
"""
import re, sys, glob, os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
FIX = '--fix' in sys.argv
problems = []


def rd(path):
    raw = open(os.path.join(ROOT, path), 'rb').read().decode('utf-8')
    bom = raw.startswith('﻿')
    raw = raw[1:] if bom else raw
    nl = '\r\n' if '\r\n' in raw else '\n'
    return raw.replace('\r\n', '\n'), bom, nl


def wr(path, text, bom, nl):
    open(os.path.join(ROOT, path), 'wb').write((('﻿' if bom else '') + text.replace('\n', nl)).encode('utf-8'))


def bad(path, msg):
    problems.append(f'{path}: {msg}')


# ---- 1. structure from _quarto.yml -----------------------------------------------------------
yml, ybom, ynl = rd('_quarto.yml')
modules = []          # [(part_line_title, [files])]
in_book_chapters = False
for line in yml.split('\n'):
    if re.match(r'^\s*appendices:', line):
        break
    m = re.match(r'^\s*-\s+part:\s*"?(.*?)"?\s*$', line)
    if m:
        modules.append((m.group(1), [])); continue
    m = re.match(r'^\s+-\s+(\S+\.qmd)\s*$', line)
    if m and modules:
        modules[-1][1].append(m.group(1))

position = {}         # file -> (module, part)
for mi, (_, files) in enumerate(modules, 1):
    for pi, f in enumerate(files):
        position[f] = (mi, pi)

# ---- 2. renumber typed spots ----------------------------------------------------------------
ynew = yml
for mi, (title, _) in enumerate(modules, 1):
    want = re.sub(r'^\s*Module\s+\d+\s*:', f'Module {mi}:', title)
    if want != title:
        bad('_quarto.yml', f'part "{title}" should be "{want}"')
        ynew = ynew.replace(title, want, 1)

heading_ids = {}      # id -> file
label_ids = {}
file_text = {}
for f, (m, p) in position.items():
    text, bom, nl = rd(f)
    orig = text
    file_text[f] = text
    # front matter
    fm = re.match(r'^---\n(.*?)\n---', text, flags=re.S)
    if not fm:
        bad(f, 'no front matter'); continue
    if not re.search(r'^xref:\s*\S+', fm.group(1), flags=re.M):
        bad(f, 'missing `xref:` label in front matter')
    else:
        lab = re.search(r'^xref:\s*(\S+)', fm.group(1), flags=re.M).group(1)
        if lab in label_ids: bad(f, f'duplicate xref label {lab} (also {label_ids[lab]})')
        label_ids[lab] = f
    tm = re.search(r'^title:\s*"(.*?)"\s*$', fm.group(1), flags=re.M)
    if tm:
        t = tm.group(1)
        if p == 0:
            nt = re.sub(r'^Module\s+\d+\s*:', f'Module {m}:', t)
        else:
            nt = re.sub(r'^Part\s+\d+\s*:', f'Part {p}:', t)
        if nt != t:
            bad(f, f'title "{t}" should start "{nt.split(":")[0]}:"')
            text = text.replace(f'title: "{t}"', f'title: "{nt}"', 1)
    if p > 0:
        for h in re.finditer(r'^# Part (\d+):', text, flags=re.M):
            if int(h.group(1)) != p:
                bad(f, f'heading "# Part {h.group(1)}:" should be "# Part {p}:"')
        text = re.sub(r'^# Part \d+:', f'# Part {p}:', text, flags=re.M)
        for im in re.finditer(r'title="Module (\d+) Part (\d+):', text):
            if (int(im.group(1)), int(im.group(2))) != (m, p):
                bad(f, f'iframe title "Module {im.group(1)} Part {im.group(2)}:" should be "Module {m} Part {p}:"')
        text = re.sub(r'title="Module \d+ Part \d+:', f'title="Module {m} Part {p}:', text)
    # ids (outside code fences)
    fence = None
    for line in text.split('\n'):
        fm2 = re.match(r'^\s*(```+|~~~+)', line)
        if fm2:
            fence = None if fence else fm2.group(1); continue
        if fence: continue
        hm = re.match(r'^#+\s+.*\{[^{}]*#([\w:.\-]+)[^{}]*\}\s*$', line)
        if hm:
            i = hm.group(1)
            if i in heading_ids and heading_ids[i] != f:
                bad(f, f'duplicate heading id #{i} (also in {heading_ids[i]})')
            heading_ids[i] = f
    file_text[f] = text
    if FIX and text != orig:
        wr(f, text, bom, nl)
if FIX and ynew != yml:
    wr('_quarto.yml', ynew, ybom, ynl)

# ---- 3. shortcodes resolve -------------------------------------------------------------------
known = set(heading_ids) | set(label_ids)
SC = re.compile(r'\{\{<\s*ref\s+([^\s>]+)')
HARD = re.compile(r'\b(Parts? \d+|Modules? \d+|Sections? \d+(\.\d+)?|Cases? \d+)\b')
for f in list(position) + ['index.qmd']:
    text = file_text.get(f) or rd(f)[0]
    fence = None; in_yaml = False
    for n, line in enumerate(text.split('\n'), 1):
        if n == 1 and line.strip() == '---': in_yaml = True; continue
        if in_yaml:
            if line.strip() == '---': in_yaml = False
            continue
        fm2 = re.match(r'^\s*(```+|~~~+)', line)
        if fm2:
            fence = None if fence else fm2.group(1); continue
        if fence: continue
        for m in SC.finditer(line):
            if m.group(1) not in known:
                bad(f'{f}:{n}', f'{{{{< ref {m.group(1)} >}}}} does not match any heading id or xref label')
        if line.startswith('<iframe') or 'xref-ok' in line:
            continue
        stripped = re.sub(r'\{\{<.*?>\}\}|`[^`]*`|\]\([^)]*\)', '', line)
        # own-part H1 and local labels are maintained by --fix / are intentionally local
        if re.match(r'^# Part \d+:', stripped): continue
        # local labels inside one part ("## Case 2 — ...", "## Section 3: ...", "**Case 4:** ...") are intentional
        if re.match(r'^(#+\s+|\*\*)(Case|Section)\s+\d+', stripped): continue
        for h in HARD.finditer(stripped):
            bad(f'{f}:{n}', f'hard-coded reference "{h.group(0)}" -> use {{{{< ref ... >}}}}')

print(('FIXED titles in place; ' if FIX else '') + f'{len(position)} chapters, {len(known)} ids/labels checked.')
if problems:
    # after --fix, numbering messages describe what was changed
    for p in problems: print(' -', p)
    sys.exit(0 if FIX and all(('hard-coded' not in p and 'does not match' not in p and 'duplicate' not in p and 'missing' not in p) for p in problems) else 1)
print('OK: no problems found.')
