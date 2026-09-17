#!/usr/bin/env python3
"""Differential test of the hand-written C# parser against tree-sitter-c-sharp.

For every .cs file given (files or directories), `udon2godot --ast-summary` exports what the
converter's parser produced (types, members, parameter counts and per-member counts of statement
and expression kinds); the same summary is computed from tree-sitter's tree and the two are
compared. A construct the hand-written parser drops, splits or attaches to the wrong member shows
up as a difference.

    pip install tree-sitter tree-sitter-c-sharp        # once (a venv is fine)
    tools/parser_diff.py refs/MS-VRCSA-Billiards refs/vrcbce refs/SaccFlightAndVehicles tests

Exit code 1 when any file differs. Files tree-sitter itself cannot parse cleanly, or that the
converter rejects (non-UdonSharp editor code), are listed separately and do not count.
"""
import collections
import json
import os
import subprocess
import sys
import tempfile

import tree_sitter_c_sharp
from tree_sitter import Language, Parser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, 'target', 'release', 'udon2godot')

STMT = {
    'if_statement': 'if', 'while_statement': 'while', 'do_statement': 'do', 'for_statement': 'for',
    'foreach_statement': 'foreach', 'switch_statement': 'switch', 'switch_section': 'switch_label',
    'break_statement': 'break', 'continue_statement': 'continue', 'return_statement': 'return',
    'throw_statement': 'throw', 'try_statement': 'try', 'lock_statement': 'lock',
    'goto_statement': 'goto', 'labeled_statement': 'label', 'local_declaration_statement': 'local',
    'expression_statement': 'expr_stmt',
}
EXPR = {
    'invocation_expression': 'call', 'object_creation_expression': 'new',
    'array_creation_expression': 'new_array', 'implicit_array_creation_expression': 'new_array',
    'assignment_expression': 'assign', 'binary_expression': 'binary',
    'prefix_unary_expression': 'unary', 'postfix_unary_expression': 'unary',
    'conditional_expression': 'cond', 'cast_expression': 'cast', 'is_expression': 'is',
    'is_pattern_expression': 'is', 'as_expression': 'as', 'lambda_expression': 'lambda',
    'anonymous_method_expression': 'lambda', 'interpolated_string_expression': 'interp',
    'member_access_expression': 'member', 'member_binding_expression': 'member',
    'element_access_expression': 'index', 'element_binding_expression': 'index',
    'throw_expression': 'throw',
}


def text(node):
    return node.text.decode('utf8', 'replace')


# --- the converter's lexer evaluates #if with a fixed symbol set and drops inactive branches; the
# same is done to the text tree-sitter sees (which otherwise keeps every branch) -----------------
DEFINED = ['UDON', 'UDONSHARP', 'COMPILER_UDONSHARP', 'VRC_SDK_VRCSDK3']


def pp_eval(expr, defined):
    import re
    toks = re.findall(r'\|\||&&|==|!=|[!()]|[A-Za-z_][A-Za-z0-9_]*', expr)
    pos = [0]

    def unary():
        if pos[0] >= len(toks):
            return False
        t = toks[pos[0]]
        pos[0] += 1
        if t == '!':
            return not unary()
        if t == '(':
            v = or_()
            if pos[0] < len(toks) and toks[pos[0]] == ')':
                pos[0] += 1
            return v
        return True if t == 'true' else False if t == 'false' else t in defined

    def eq():
        v = unary()
        while pos[0] < len(toks) and toks[pos[0]] in ('==', '!='):
            op = toks[pos[0]]
            pos[0] += 1
            r = unary()
            v = (v == r) if op == '==' else (v != r)
        return v

    def and_():
        v = eq()
        while pos[0] < len(toks) and toks[pos[0]] == '&&':
            pos[0] += 1
            r = eq()
            v = v and r
        return v

    def or_():
        v = and_()
        while pos[0] < len(toks) and toks[pos[0]] == '||':
            pos[0] += 1
            r = and_()
            v = v or r
        return v

    return or_()


def preprocess(src):
    """Blank out inactive #if branches and the directive lines (line numbers are preserved)."""
    defined = list(DEFINED)
    stack = []  # (active, taken, parent)
    out = []
    for line in src.decode('utf-8-sig', 'replace').split('\n'):
        s = line.strip()
        active = stack[-1][0] if stack else True
        if s.startswith('#'):
            body = s[1:].strip()
            name, _, rest = body.partition(' ')
            rest = rest.split('//')[0].strip()
            if name == 'if':
                v = pp_eval(rest, defined)
                stack.append((active and v, v, active))
            elif name == 'elif' and stack:
                _, taken, parent = stack.pop()
                v = pp_eval(rest, defined)
                stack.append((parent and not taken and v, taken or v, parent))
            elif name == 'else' and stack:
                _, taken, parent = stack.pop()
                stack.append((parent and not taken, True, parent))
            elif name == 'endif' and stack:
                stack.pop()
            elif name == 'define' and active:
                defined.append(rest)
            elif name == 'undef' and active and rest in defined:
                defined.remove(rest)
            out.append('')
        else:
            out.append(line if active else '')
    return '\n'.join(out).encode('utf8')


def folded_negative(node):
    """`-1`, `-2.5f`: the hand-written parser folds the sign into the literal."""
    if node.type != 'prefix_unary_expression' or node.child_count != 2 or text(node.children[0]) != '-':
        return False
    lit = node.children[1]
    if lit.type not in ('integer_literal', 'real_literal'):
        return False
    low = text(lit).lower()
    return not (low.endswith('u') or low.endswith('ul') or low.endswith('lu') or low.endswith('m'))


def spec_binary_not_cast(node):
    """`(name) & x`, `(name) - x`, `(name) * x`, `(name) + x`: the C# spec reads a parenthesized
    name followed by one of these operators as a binary expression; tree-sitter (no type
    information) guesses a cast of a unary expression."""
    if node.type != 'cast_expression':
        return False
    ty = node.child_by_field_name('type')
    val = node.child_by_field_name('value')
    if ty is None or val is None or ty.type not in ('identifier', 'qualified_name'):
        return False
    return val.type == 'prefix_unary_expression' and val.child_count == 2 and text(val.children[0]) in ('&', '-', '+', '*')


def pointer_declaration_is_product(node):
    """`f(a * b)`: tree-sitter reads `a* b` as a declaration expression of a pointer type."""
    if node.type != 'declaration_expression':
        return False
    ty = node.child_by_field_name('type')
    return ty is not None and ty.type == 'pointer_type'


def is_nameof(node):
    return node.type == 'invocation_expression' and node.child_count > 0 and node.children[0].type == 'identifier' and text(node.children[0]) == 'nameof'


def count(node, c, in_for_header=False):
    """Counts statement and expression kinds below `node` the way src/summary.rs does."""
    t = node.type
    if spec_binary_not_cast(node):
        # count it the way the spec parses it: one binary expression, no cast, no unary
        c['binary'] += 1
        ty = node.child_by_field_name('type')
        val = node.child_by_field_name('value')
        count(ty, c)
        if ty.type == 'qualified_name':
            c['member'] += text(ty).count('.')
        count(val.children[1], c)
        return
    if pointer_declaration_is_product(node):
        c['binary'] += 1
        ty = node.child_by_field_name('type')
        c['member'] += text(ty).count('.')
        return
    if t in STMT:
        c[STMT[t]] += 1
    elif t in EXPR and not folded_negative(node) and not is_nameof(node):
        c[EXPR[t]] += 1
    if t == 'accessor_declaration':
        # `get => x;` / `set => x = value;` are desugared to a return / an expression statement
        if any(ch.type == 'arrow_expression_clause' for ch in node.children):
            c['return' if text(node.children[0]) == 'get' or any(text(ch) == 'get' for ch in node.children if not ch.is_named) else 'expr_stmt'] += 1
    if t == 'variable_declarator' and node.parent is not None and node.parent.type == 'variable_declaration':
        gp = node.parent.parent
        if gp is not None and gp.type in ('local_declaration_statement', 'for_statement'):
            c['declarator'] += 1
    for ch in node.children:
        count(ch, c)


def member_counts(node):
    c = collections.Counter()
    if node is not None:
        count(node, c)
    return dict(c)


def declared_name(node):
    n = node.child_by_field_name('name')
    return text(n) if n is not None else '?'


def ts_type(node):
    if node.type == 'enum_declaration':
        body = node.child_by_field_name('body')
        n = sum(1 for ch in body.children if ch.type == 'enum_member_declaration') if body else 0
        return {'kind': 'enum', 'name': declared_name(node), 'members': n}
    out = {'kind': 'class', 'name': declared_name(node), 'fields': [], 'field_init': collections.Counter(), 'props': [], 'methods': [], 'nested': []}
    body = node.child_by_field_name('body')
    for m in (body.children if body is not None else []):
        if m.type == 'field_declaration' or m.type == 'event_field_declaration':
            for decl in m.children:
                if decl.type == 'variable_declaration':
                    for d in decl.children:
                        if d.type == 'variable_declarator':
                            out['fields'].append(declared_name(d))
                            for ch in d.children:
                                count(ch, out['field_init'])
        elif m.type in ('property_declaration', 'indexer_declaration'):
            c = collections.Counter()
            for ch in m.children:
                if ch.type in ('accessor_list', 'arrow_expression_clause', 'equals_value_clause') or (m.child_by_field_name('value') is not None and ch == m.child_by_field_name('value')):
                    count(ch, c)
            out['props'].append({'name': declared_name(m) if m.type == 'property_declaration' else 'this', 'counts': dict(c)})
        elif m.type in ('method_declaration', 'constructor_declaration', 'operator_declaration', 'destructor_declaration'):
            params = m.child_by_field_name('parameters')
            n_params = 0
            if params is not None:
                # a `params T[] name` parameter is an array_type + identifier directly in the list
                n_params = sum(1 for ch in params.children if ch.type == 'parameter') + sum(1 for ch in params.children if ch.type == 'identifier')
            body_node = m.child_by_field_name('body')
            c = collections.Counter()
            if body_node is not None:
                count(body_node, c)
                if body_node.type == 'arrow_expression_clause':
                    # `T F() => e;` is desugared to `return e;` (an expression statement when void)
                    rt = m.child_by_field_name('returns') or m.child_by_field_name('type')
                    c['expr_stmt' if rt is not None and text(rt) == 'void' else 'return'] += 1
            out['methods'].append({'kind': 'ctor' if m.type == 'constructor_declaration' else 'method', 'name': declared_name(m), 'params': n_params, 'has_body': body_node is not None, 'counts': dict(c)})
        elif m.type in ('class_declaration', 'struct_declaration', 'interface_declaration', 'enum_declaration'):
            out['nested'].append(ts_type(m))
    out['field_init'] = dict(out['field_init'])
    return out


def ts_types(node, acc):
    for ch in node.children:
        if ch.type in ('class_declaration', 'struct_declaration', 'interface_declaration', 'enum_declaration'):
            acc.append(ts_type(ch))
        elif ch.type in ('namespace_declaration', 'file_scoped_namespace_declaration', 'declaration_list'):
            ts_types(ch, acc)
    return acc


def strip_zero(d):
    return {k: v for k, v in d.items() if v}


def diff_type(path, a, b, out):
    """a = converter's parser, b = tree-sitter."""
    where = f"{path}: {a.get('name')}"
    if a['kind'] != b['kind']:
        out.append(f"{where}: kind {a['kind']} vs {b['kind']}")
        return
    if a['kind'] == 'enum':
        if a['members'] != b['members']:
            out.append(f"{where}: enum members {a['members']} vs {b['members']}")
        return
    if sorted(a['fields']) != sorted(b['fields']):
        out.append(f"{where}: fields differ: only ours {sorted(set(a['fields']) - set(b['fields']))}, only tree-sitter {sorted(set(b['fields']) - set(a['fields']))}")
    if strip_zero(a['field_init']) != strip_zero(b['field_init']):
        out.append(f"{where}: field initializers: {strip_zero(a['field_init'])} vs {strip_zero(b['field_init'])}")
    pa = {p['name']: strip_zero(p['counts']) for p in a['props']}
    pb = {p['name']: strip_zero(p['counts']) for p in b['props']}
    if pa != pb:
        for k in sorted(set(pa) | set(pb)):
            if pa.get(k) != pb.get(k):
                out.append(f"{where}.{k} (property): {pa.get(k)} vs {pb.get(k)}")
    ma = collections.defaultdict(list)
    mb = collections.defaultdict(list)
    for m in a['methods']:
        ma[(m['name'], m['params'])].append(m)
    for m in b['methods']:
        mb[(m['name'], m['params'])].append(m)
    for k in sorted(set(ma) | set(mb)):
        la, lb = ma.get(k, []), mb.get(k, [])
        if len(la) != len(lb):
            out.append(f"{where}.{k[0]}/{k[1]}: {len(la)} declaration(s) vs {len(lb)}")
            continue
        for x, y in zip(la, lb):
            if x['has_body'] != y['has_body'] or strip_zero(x['counts']) != strip_zero(y['counts']):
                ca, cb = strip_zero(x['counts']), strip_zero(y['counts'])
                delta = {kk: (ca.get(kk, 0), cb.get(kk, 0)) for kk in sorted(set(ca) | set(cb)) if ca.get(kk, 0) != cb.get(kk, 0)}
                out.append(f"{where}.{k[0]}/{k[1]}: (ours, tree-sitter) {delta}")
    na = {t['name']: t for t in a['nested']}
    nb = {t['name']: t for t in b['nested']}
    for k in sorted(set(na) | set(nb)):
        if k not in na or k not in nb:
            out.append(f"{where}: nested type {k} only in {'ours' if k in na else 'tree-sitter'}")
        else:
            diff_type(path, na[k], nb[k], out)


def main():
    inputs = sys.argv[1:] or ['tests']
    files = []
    for inp in inputs:
        if os.path.isdir(inp):
            for dp, dn, fn in os.walk(inp):
                if '/Editor' in dp.replace('\\', '/') + '/' or '/.git' in dp:
                    continue
                files += [os.path.join(dp, f) for f in fn if f.endswith('.cs')]
        elif inp.endswith('.cs'):
            files.append(inp)
    files.sort()
    parser = Parser(Language(tree_sitter_c_sharp.language()))
    differing, rejected, ts_errors, same = [], [], [], 0
    with tempfile.TemporaryDirectory() as tmp:
        for f in files:
            src = preprocess(open(f, 'rb').read())
            tree = parser.parse(src)
            if tree.root_node.has_error:
                ts_errors.append(f)
                continue
            out_json = os.path.join(tmp, 's.json')
            r = subprocess.run([BIN, '-q', '--ast-summary', out_json, f], capture_output=True, text=True)
            if r.returncode != 0 or not os.path.exists(out_json):
                rejected.append((f, (r.stderr or r.stdout).strip().splitlines()[:1]))
                continue
            ours = json.load(open(out_json))[0]['types']
            os.remove(out_json)
            theirs = ts_types(tree.root_node, [])
            out = []
            oa = {t['name']: t for t in ours}
            ob = {t['name']: t for t in theirs}
            for k in sorted(set(oa) | set(ob)):
                if k not in oa or k not in ob:
                    out.append(f"{f}: type {k} only in {'ours' if k in oa else 'tree-sitter'}")
                else:
                    diff_type(f, oa[k], ob[k], out)
            if out:
                differing.append((f, out))
            else:
                same += 1
    print(f"{len(files)} files: {same} identical, {len(differing)} differ, {len(rejected)} rejected by the converter's parser, {len(ts_errors)} with tree-sitter errors")
    for f, lines in differing:
        for l in lines[:12]:
            print("  DIFF " + l)
    for f, why in rejected:
        print(f"  REJECTED {f}: {' '.join(why)}")
    for f in ts_errors:
        print(f"  TS-ERROR {f}")
    sys.exit(1 if differing or rejected else 0)


if __name__ == '__main__':
    main()
