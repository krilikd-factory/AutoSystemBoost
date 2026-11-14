#!/usr/bin/env python3
"""Keep the WebUI stylesheet bucketable (dev55). Not shipped; run on the host.

Chromium sorts every style rule by the class, id or element name of its rightmost compound
and tests an element only against the rules filed under its own classes, id and tag. A rule
whose rightmost compound is a bare :is(.a, .b, ...) list has nothing to be filed under, so it
was tested against every element on every style recalc: 72 such selectors were half of the
selector-matching time of a full recalc in the dev54 WebUI.

This tool rewrites such a selector into the equivalent plain selector list, in place:

    html[data-asb-theme="light"] :is(.a, .b.c)  ->  html[data-asb-theme="light"] .a.a,
                                                     html[data-asb-theme="light"] .b.c

Equivalence rules (any other selector is left untouched and listed with --report):
  * the rightmost compound is ':is(A1, ..., An)REST' with nothing filable before ':is(';
  * every Ai is a single compound, or the prefix consists of root-element compounds only
    (html / :root, descendant combinator) and no Ai can start on <html> itself;
  * every Ai is raised to the :is() weight (its largest argument) without changing what it
    matches: a class it already has is repeated, otherwise :not(.asb-spec-pad),
    :not(asb-spec-pad) or :not(#asb-spec-pad) is added - a class, element name and id the
    page never uses, so each matches every element and only adds its own weight.
The rule keeps its place and every produced selector has exactly the specificity the :is()
selector had, so the cascade is unchanged. The dev55 rewrite was checked by comparing every
computed property of every element and its ::before/::after in 64 UI states (4 themes).

usage: asb_css_bucket.py webroot/index.html            rewrite in place
       asb_css_bucket.py webroot/index.html --check    exit 1 if anything is left to rewrite
       asb_css_bucket.py webroot/index.html --report   also list the selectors left alone
"""
import re
import sys

HTML_CLASSES = {'asb-calm', 'asb-fit-c1', 'asb-fit-c2', 'asb-bar-hidden'}


def split_top(s, seps=','):
    out, cur, depth, quote, i = [], '', 0, None, 0
    while i < len(s):
        c = s[i]
        if quote:
            cur += c
            if c == '\\' and i + 1 < len(s):
                cur += s[i + 1]; i += 2; continue
            if c == quote: quote = None
        elif c in '"\'':
            quote = c; cur += c
        elif c in '([':
            depth += 1; cur += c
        elif c in ')]':
            depth -= 1; cur += c
        elif depth == 0 and c in seps:
            out.append(cur); cur = ''
        else:
            cur += c
        i += 1
    out.append(cur)
    return out


def compounds(sel):
    """[(combinator_before, compound)] for one complex selector."""
    s = sel.strip()
    parts, cur, depth, quote, i, comb = [], '', 0, None, 0, ''
    while i < len(s):
        c = s[i]
        if quote:
            cur += c
            if c == quote: quote = None
            i += 1; continue
        if c in '"\'':
            quote = c; cur += c; i += 1; continue
        if c in '([':
            depth += 1; cur += c; i += 1; continue
        if c in ')]':
            depth -= 1; cur += c; i += 1; continue
        if depth == 0 and (c.isspace() or c in '>+~'):
            j = i; k = ''
            while j < len(s) and (s[j].isspace() or s[j] in '>+~'):
                if s[j] in '>+~': k = s[j]
                j += 1
            if cur:
                parts.append((comb, cur)); cur = ''
            comb = k or ' '
            i = j; continue
        cur += c; i += 1
    if cur: parts.append((comb, cur))
    return parts


def top_simple(compound):
    """The compound with parenthesised/bracketed content removed (depth-0 text only)."""
    out, depth, quote = '', 0, None
    for c in compound:
        if quote:
            if c == quote: quote = None
            continue
        if c in '"\'' and depth: quote = c; continue
        if c in '([':
            depth += 1
            if depth == 1: out += c
            continue
        if c in ')]':
            depth -= 1
            if depth == 0: out += c
            continue
        if depth == 0: out += c
    return out


def bucketable(compound):
    t = top_simple(compound)
    return bool(re.match(r'^[a-zA-Z]', t)) or '.' in t.split(':')[0] or '#' in t.split(':')[0] or bool(re.search(r'(^|[^:(])[.#][A-Za-z_\\-]', t))


def specificity(sel):
    a = b = c = 0
    for _, comp in compounds(sel):
        x, y, z = spec_compound(comp)
        a += x; b += y; c += z
    return (a, b, c)


def spec_compound(comp):
    a = b = c = 0
    i = 0
    s = comp
    while i < len(s):
        ch = s[i]
        if ch == '#':
            a += 1; i += 1
            while i < len(s) and (s[i].isalnum() or s[i] in '-_\\'): i += 1
        elif ch == '.':
            b += 1; i += 1
            while i < len(s) and (s[i].isalnum() or s[i] in '-_\\'): i += 1
        elif ch == '[':
            b += 1; d = 0
            while i < len(s):
                if s[i] == '[': d += 1
                elif s[i] == ']':
                    d -= 1
                    if d == 0: break
                i += 1
            i += 1
        elif ch == ':':
            if s[i:i + 2] == '::':
                c += 1; i += 2
                while i < len(s) and (s[i].isalnum() or s[i] == '-'): i += 1
                if i < len(s) and s[i] == '(':
                    i = skip_paren(s, i)
                continue
            i += 1
            j = i
            while j < len(s) and (s[j].isalnum() or s[j] == '-'): j += 1
            name = s[i:j].lower()
            if j < len(s) and s[j] == '(':
                end = skip_paren(s, j)
                inner = s[j + 1:end - 1]
                if name in ('is', 'not', 'has'):
                    best = max((specificity(x) for x in split_top(inner)), default=(0, 0, 0))
                    a += best[0]; b += best[1]; c += best[2]
                elif name == 'where':
                    pass
                elif name in ('nth-child', 'nth-last-child'):
                    b += 1
                    m = re.search(r'\bof\b(.*)$', inner)
                    if m:
                        best = max((specificity(x) for x in split_top(m.group(1))), default=(0, 0, 0))
                        a += best[0]; b += best[1]; c += best[2]
                elif name in ('before', 'after', 'first-line', 'first-letter'):
                    c += 1
                else:
                    b += 1
                i = end
            else:
                if name in ('before', 'after', 'first-line', 'first-letter'):
                    c += 1
                else:
                    b += 1
                i = j
        elif ch == '*':
            i += 1
        elif ch.isalpha():
            c += 1
            while i < len(s) and (s[i].isalnum() or s[i] in '-_'): i += 1
        else:
            i += 1
    return (a, b, c)


def skip_paren(s, i):
    d = 0
    while i < len(s):
        if s[i] == '(': d += 1
        elif s[i] == ')':
            d -= 1
            if d == 0: return i + 1
        i += 1
    return i


def root_only(prefix_parts):
    for comb, comp in prefix_parts:
        if comb not in ('', ' '): return False
        t = comp.strip()
        if not (t.startswith('html') or t.startswith(':root')): return False
    return True


def pad(arg, da, db, dc):
    """Raise arg's specificity by (da, db, dc) without changing what it matches: a repeated
    class already in the rightmost compound, else :not() of an id / class / element name
    that the page never uses (each matches every element and adds its own weight)."""
    if da == db == dc == 0: return arg
    parts = compounds(arg)
    comb, comp = parts[-1]
    add = ''
    m = re.search(r'\.([A-Za-z_][\w-]*)', top_simple(comp))
    if db and m:
        add += ('.' + m.group(1)) * db
    elif db:
        add += ':not(.asb-spec-pad)' * db
    add += ':not(#asb-spec-pad)' * da + ':not(asb-spec-pad)' * dc
    pe = comp.find('::')
    comp2 = comp + add if pe < 0 else comp[:pe] + add + comp[pe:]
    if db and m and pe < 0:
        cls = '.' + m.group(1); idx = comp.find(cls)
        comp2 = comp[:idx + len(cls)] + cls * db + comp[idx + len(cls):] + ':not(#asb-spec-pad)' * da + ':not(asb-spec-pad)' * dc
    parts[-1] = (comb, comp2)
    return join(parts)


def join(parts):
    out = ''
    for comb, comp in parts:
        if not out: out = comp
        elif comb == ' ': out += ' ' + comp
        else: out += ' ' + comb + ' ' + comp
    return out


def first_compound_may_be_html(arg):
    comp = compounds(arg)[0][1]
    t = top_simple(comp)
    if t.startswith('html') or t.startswith(':root'): return True
    classes = set(re.findall(r'\.([A-Za-z_][\w-]*)', t))
    if classes & HTML_CLASSES: return True
    if not classes and not re.match(r'^[a-zA-Z]', t): return True
    return False


def rewrite_selector(sel, report):
    parts = compounds(sel)
    if not parts: return [sel]
    comb, last = parts[-1]
    if bucketable(last): return [sel]
    if not last.startswith(':is('):
        report.append(('skip-not-is', sel.strip())); return [sel]
    end = skip_paren(last, 3)
    args = [a.strip() for a in split_top(last[4:end - 1])]
    rest = last[end:]
    if not all(args):
        report.append(('skip-empty-arg', sel.strip())); return [sel]
    multi = any(len(compounds(a)) > 1 for a in args)
    prefix = parts[:-1]
    if multi:
        if not root_only(prefix) or comb not in ('', ' ') or any(first_compound_may_be_html(a) for a in args):
            report.append(('skip-complex-arg', sel.strip())); return [sel]
    specs = [specificity(a) for a in args]
    tgt = max(specs)
    out_args = []
    tgt = (max(sp[0] for sp in specs), max(sp[1] for sp in specs), max(sp[2] for sp in specs))
    # the :is() weight is the largest argument's (lexicographic), not a per-component max
    tgt = max(specs)
    for a, sp in zip(args, specs):
        da, db, dc = tgt[0] - sp[0], tgt[1] - sp[1], tgt[2] - sp[2]
        if da < 0 or db < 0 or dc < 0:
            report.append(('skip-spec', sel.strip())); return [sel]
        out_args.append(pad(a, da, db, dc))
        assert specificity(out_args[-1]) == tgt, (out_args[-1], specificity(out_args[-1]), tgt)
    res = []
    for a in out_args:
        a_parts = compounds(a)
        a_parts[-1] = (a_parts[-1][0], a_parts[-1][1] + rest)
        if prefix:
            a_parts[0] = (comb, a_parts[0][1])
            res.append(join(prefix + a_parts))
        else:
            res.append(join(a_parts))
    # the expanded rightmost compounds must now be bucketable, or there is no point
    if not any(bucketable(compounds(r)[-1][1]) for r in res):
        report.append(('skip-still-universal', sel.strip())); return [sel]
    report.append(('rewrite', sel.strip(), res))
    return res


def rewrite_prelude(prelude, report):
    comments = re.findall(r'/\*.*?\*/', prelude, flags=re.S)
    if comments:
        bare = re.sub(r'/\*.*?\*/', ' ', prelude, flags=re.S)
        new = rewrite_prelude(bare, report)
        if new == bare: return prelude
        lead = new[:len(new) - len(new.lstrip())]
        return lead + '\n'.join(comments) + '\n' + new.lstrip()
    sels = split_top(prelude)
    lead = prelude[:len(prelude) - len(prelude.lstrip())]
    trail = prelude[len(prelude.rstrip()):]
    out, changed = [], False
    for s in sels:
        r = rewrite_selector(s, report)
        if r != [s]: changed = True
        out.extend(x.strip() for x in r)
    if not changed: return prelude
    return lead + ',\n'.join(out) + trail


def transform_css(css, report):
    out, i, n = [], 0, len(css)
    buf_start = 0
    stack = []  # 'rules' or 'keep'
    prelude_start = 0
    while i < n:
        c = css[i]
        if css.startswith('/*', i):
            j = css.find('*/', i + 2); j = n if j < 0 else j + 2
            i = j; continue
        if c in '"\'':
            j = i + 1
            while j < n and css[j] != c:
                if css[j] == '\\': j += 1
                j += 1
            i = j + 1; continue
        if c == '{':
            prelude = css[prelude_start:i]
            in_keep = stack and stack[-1] == 'keep'
            p = prelude.strip()
            # strip leading comments for classification
            p_nc = re.sub(r'/\*.*?\*/', '', prelude, flags=re.S).strip()
            if in_keep or (stack and stack[-1] == 'decl'):
                stack.append('keep')
            elif p_nc.startswith('@'):
                stack.append('rules' if re.match(r'@(media|supports|layer|container|document)\b', p_nc) else 'keep')
            else:
                # style rule: rewrite selector part (comments preserved before it)
                m = re.match(r'(\s*(?:/\*.*?\*/\s*)*)(.*)$', prelude, flags=re.S)
                head, sel = m.group(1), m.group(2)
                new = rewrite_prelude(sel, report)
                if new != sel:
                    out.append(css[buf_start:prelude_start]); out.append(head + new); buf_start = i
                stack.append('decl')
            i += 1; prelude_start = i; continue
        if c == '}':
            if stack: stack.pop()
            i += 1; prelude_start = i; continue
        if c == ';' and (not stack or stack[-1] == 'rules'):
            i += 1; prelude_start = i; continue
        if c == ';' and stack and stack[-1] == 'decl':
            i += 1; continue
        i += 1
    out.append(css[buf_start:])
    return ''.join(out)


def main():
    path = sys.argv[1]
    html = open(path, encoding='utf-8').read()
    HTML_CLASSES.update(re.findall(r"(?:documentElement|\broot)\.classList\.\w+\('([\w-]+)'", html))
    report = []

    def sub(m):
        return m.group(1) + transform_css(m.group(2), report) + m.group(3)
    new = re.sub(r'(<style[^>]*>)(.*?)(</style>)', sub, html, flags=re.S)
    done = [r for r in report if r[0] == 'rewrite']
    if '--report' in sys.argv:
        for r in report:
            if r[0] != 'rewrite':
                print(r[0], '|', ' '.join(r[1].split())[:160])
    if '--check' in sys.argv:
        for r in done:
            print('not bucketed:', ' '.join(r[1].split())[:200])
        print('asb_css_bucket: %d selector(s) left to rewrite' % len(done))
        return 1 if done else 0
    if new != html:
        open(path, 'w', encoding='utf-8').write(new)
    print('asb_css_bucket: rewrote %d selector(s) into %d' % (len(done), sum(len(r[2]) for r in done)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
