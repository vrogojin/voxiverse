#!/usr/bin/env python3
"""Recover top-level boolean `const` values from a Godot 4.4 exported pack.

The live VOXIVERSE web build was exported with ~217 feature flags flipped ON by
a sed step that was reverted right after the export, so the exported pack is
the only record of which flags were ON. This tool reads that pack, decodes
every compiled GDScript (.gdc, binary-token format) and prints every top-level
`const NAME := <bool>` / `const NAME = <bool>` / `const NAME: bool = <bool>`.

Usage:
    python3 extract_pck_flags.py PACK.pck                 # table to stdout
    python3 extract_pck_flags.py PACK.pck --json OUT.json # also write JSON
    python3 extract_pck_flags.py PACK.pck --list          # list pack entries
    python3 extract_pck_flags.py PACK.pck --self-test     # format checks only

Optional source comparison (adds source_default to each record):
    python3 extract_pck_flags.py PACK.pck --source-dir path/to/godot \
        --json live-flags.json
`--source-dir` is the directory that `res://` maps to (the folder holding
project.godot). Source files are read as `<source-dir>/<res path>.gd`.

Dependencies: Python 3.8+ standard library. zstd decompression uses the
system libzstd through ctypes (or the `zstandard` module when installed).

Format references (Godot 4.4 source):
  core/io/file_access_pack.cpp           PCK directory (format version 2)
  modules/gdscript/gdscript_tokenizer_buffer.cpp   binary tokens
  core/io/marshalls.cpp                   encode_variant
Every structural assumption below is checked while decoding; a mismatch
raises instead of guessing.
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import re
import struct
import sys

# --------------------------------------------------------------------------
# zstd
# --------------------------------------------------------------------------


def _zstd_decompress(data, out_size):
    try:
        import zstandard  # type: ignore

        return zstandard.ZstdDecompressor().decompress(data, max_output_size=out_size)
    except ImportError:
        pass
    name = ctypes.util.find_library('zstd') or 'libzstd.so.1'
    lib = ctypes.CDLL(name)
    lib.ZSTD_decompress.restype = ctypes.c_size_t
    lib.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
    lib.ZSTD_isError.restype = ctypes.c_uint
    lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
    dst = ctypes.create_string_buffer(out_size)
    src = ctypes.create_string_buffer(data, len(data))
    n = lib.ZSTD_decompress(dst, out_size, src, len(data))
    if lib.ZSTD_isError(n):
        raise ValueError('zstd decompression failed')
    if n != out_size:
        raise ValueError('zstd size mismatch: got %d expected %d' % (n, out_size))
    return dst.raw[:n]


# --------------------------------------------------------------------------
# PCK directory (Godot 4.x, pack format version 2)
# --------------------------------------------------------------------------

PACK_DIR_ENCRYPTED = 1 << 0
PACK_REL_FILEBASE = 1 << 1
PACK_FILE_ENCRYPTED = 1 << 0


def read_pck(path):
    with open(path, 'rb') as f:
        blob = f.read()
    if blob[:4] != b'GDPC':
        raise ValueError('not a PCK (magic %r)' % blob[:4])
    fmt, vmaj, vmin, vpat = struct.unpack_from('<4I', blob, 4)
    if fmt != 2:
        raise ValueError('unsupported pack format version %d (this tool reads 2)' % fmt)
    pack_flags, file_base = struct.unpack_from('<IQ', blob, 20)
    if pack_flags & PACK_DIR_ENCRYPTED:
        raise ValueError('encrypted pack directory is not supported')
    pos = 32 + 16 * 4
    (count,) = struct.unpack_from('<I', blob, pos)
    pos += 4
    entries = []
    for _ in range(count):
        (plen,) = struct.unpack_from('<I', blob, pos)
        pos += 4
        rpath = blob[pos:pos + plen].rstrip(b'\0').decode('utf-8')
        pos += plen
        ofs, size = struct.unpack_from('<QQ', blob, pos)
        pos += 16
        md5 = blob[pos:pos + 16]
        pos += 16
        (fflags,) = struct.unpack_from('<I', blob, pos)
        pos += 4
        entries.append({'path': rpath, 'ofs': ofs, 'size': size, 'md5': md5, 'flags': fflags})
    if pos > file_base:
        raise ValueError('directory overruns file_base')
    # Format v2: offsets are relative to file_base (the 4.4 writer always
    # sets file_base to the start of the file data). Verify against md5.
    pack = {'version': '%d.%d.%d' % (vmaj, vmin, vpat), 'flags': pack_flags,
            'file_base': file_base, 'entries': entries, 'blob': blob}
    return pack


def pck_file(pack, entry):
    if entry['flags'] & PACK_FILE_ENCRYPTED:
        raise ValueError('encrypted file %s not supported' % entry['path'])
    start = pack['file_base'] + entry['ofs']
    data = pack['blob'][start:start + entry['size']]
    if len(data) != entry['size']:
        raise ValueError('truncated entry %s' % entry['path'])
    if hashlib.md5(data).digest() != entry['md5']:
        raise ValueError('md5 mismatch for %s (offset base wrong?)' % entry['path'])
    return data


# --------------------------------------------------------------------------
# Variant decoding (core/io/marshalls.cpp, subset used by script literals)
# --------------------------------------------------------------------------

V_NIL, V_BOOL, V_INT, V_FLOAT, V_STRING = 0, 1, 2, 3, 4
V_STRING_NAME = 21
V_NODE_PATH = 22
ENCODE_FLAG_64 = 1 << 16


class Unsupported:
    def __init__(self, vtype):
        self.vtype = vtype

    def __repr__(self):
        return '<variant type %d>' % self.vtype


# Fixed-size math types: (count of real_t/int32 components). Script literal
# constants only produce the scalar/string types, but other types are skipped
# by size so an unexpected one is reported rather than desyncing the stream.
_FIXED = {5: 2, 6: 2, 7: 4, 8: 4, 9: 3, 10: 3, 11: 6, 12: 4, 13: 4, 14: 4,
          15: 4, 16: 6, 17: 9, 18: 12, 19: 16, 20: 4}
_INT_BASED = {6, 8, 10, 13}  # Vector2i, Rect2i, Vector3i, Vector4i


def decode_variant(buf, pos):
    (header,) = struct.unpack_from('<I', buf, pos)
    pos += 4
    vtype = header & 0xFF
    is64 = bool(header & ENCODE_FLAG_64)
    if vtype == V_NIL:
        return None, pos
    if vtype == V_BOOL:
        (v,) = struct.unpack_from('<I', buf, pos)
        if v not in (0, 1):
            raise ValueError('bool variant payload %d is not 0/1' % v)
        return bool(v), pos + 4
    if vtype == V_INT:
        if is64:
            return struct.unpack_from('<q', buf, pos)[0], pos + 8
        return struct.unpack_from('<i', buf, pos)[0], pos + 4
    if vtype == V_FLOAT:
        if is64:
            return struct.unpack_from('<d', buf, pos)[0], pos + 8
        return struct.unpack_from('<f', buf, pos)[0], pos + 4
    if vtype in (V_STRING, V_STRING_NAME):
        (n,) = struct.unpack_from('<I', buf, pos)
        pos += 4
        s = buf[pos:pos + n].decode('utf-8', 'replace')
        pos += n
        pos += (4 - n % 4) % 4
        return s, pos
    if vtype in _FIXED:
        width = 4 if (vtype in _INT_BASED or not is64) else 8
        return Unsupported(vtype), pos + _FIXED[vtype] * width
    raise ValueError('unsupported variant type %d in constant table' % vtype)


# --------------------------------------------------------------------------
# GDScript binary tokens (modules/gdscript/gdscript_tokenizer_buffer.cpp)
# --------------------------------------------------------------------------

TOKEN_BYTE_MASK = 0x80
TOKEN_BITS = 8

# GDScriptTokenizer::Token::Type as of Godot 4.4 (gdscript_tokenizer.h).
# Anchors verified against the decoded pack (see --self-test): EXTENDS=59,
# CLASS_NAME=56, TK_CONST=57, EQUAL=28, COLON=83, CONST_PI=90.
TOKEN_NAMES = [
    'EMPTY', 'ANNOTATION', 'IDENTIFIER', 'LITERAL',
    'LESS', 'LESS_EQUAL', 'GREATER', 'GREATER_EQUAL', 'EQUAL_EQUAL', 'BANG_EQUAL',
    'AND', 'OR', 'NOT', 'AMPERSAND_AMPERSAND', 'PIPE_PIPE', 'BANG',
    'AMPERSAND', 'PIPE', 'TILDE', 'CARET', 'LESS_LESS', 'GREATER_GREATER',
    'PLUS', 'MINUS', 'STAR', 'STAR_STAR', 'SLASH', 'PERCENT',
    'EQUAL', 'PLUS_EQUAL', 'MINUS_EQUAL', 'STAR_EQUAL', 'STAR_STAR_EQUAL', 'SLASH_EQUAL',
    'PERCENT_EQUAL', 'LESS_LESS_EQUAL', 'GREATER_GREATER_EQUAL', 'AMPERSAND_EQUAL',
    'PIPE_EQUAL', 'CARET_EQUAL',
    'IF', 'ELIF', 'ELSE', 'FOR', 'WHILE', 'BREAK', 'CONTINUE', 'PASS', 'RETURN', 'MATCH', 'WHEN',
    'AS', 'ASSERT', 'AWAIT', 'BREAKPOINT', 'CLASS', 'CLASS_NAME', 'TK_CONST', 'ENUM', 'EXTENDS',
    'FUNC', 'TK_IN', 'IS', 'NAMESPACE', 'PRELOAD', 'SELF', 'SIGNAL', 'STATIC', 'SUPER', 'TRAIT',
    'VAR', 'TK_VOID', 'YIELD',
    'BRACKET_OPEN', 'BRACKET_CLOSE', 'BRACE_OPEN', 'BRACE_CLOSE', 'PARENTHESIS_OPEN',
    'PARENTHESIS_CLOSE', 'COMMA', 'SEMICOLON', 'PERIOD', 'PERIOD_PERIOD',
    'COLON', 'DOLLAR', 'FORWARD_ARROW', 'UNDERSCORE',
    'NEWLINE', 'INDENT', 'DEDENT',
    'CONST_PI', 'CONST_TAU', 'CONST_INF', 'CONST_NAN',
    'VCS_CONFLICT_MARKER', 'BACKTICK', 'QUESTION_MARK',
    'ERROR', 'TK_EOF', 'TK_MAX',
]
T = {n: i for i, n in enumerate(TOKEN_NAMES)}
# Token types whose payload (token >> TOKEN_BITS) indexes a table.
IDENT_PAYLOAD = {T['IDENTIFIER'], T['ANNOTATION']}
CONST_PAYLOAD = {T['LITERAL'], T['ERROR']}


def decode_gdc(data):
    """Decode one binary-token script.

    Layout (all little-endian u32 unless noted):
      'GDSC' | tokenizer version | decompressed size (0 = stored raw) | body
      body (zstd when size != 0):
        n_identifiers | n_constants | n_line_entries | reserved (0) | n_tokens
        identifiers: len, then len UTF-32 code points each XOR 0xB6 per byte
        constants: encode_variant() values
        line table:   n_line_entries x (token index, line)
        column table: n_line_entries x (token index, column)
        tokens: first byte has 0x80 set -> u32 token (type | payload << 8)
                otherwise 1-byte token; each followed by a u32 end line.
    NEWLINE/INDENT/DEDENT are not stored; the reader rebuilds them from the
    line and column tables, so line starts and their columns are kept here.
    """
    if data[:4] != b'GDSC':
        raise ValueError('not a GDSC buffer')
    version, dsize = struct.unpack_from('<II', data, 4)
    body = data[12:]
    if dsize:
        body = _zstd_decompress(body, dsize)
    b = body
    n_ident, n_const, n_lines, reserved, n_tokens = struct.unpack_from('<5I', b, 0)
    if reserved != 0:
        raise ValueError('reserved header word is %d, expected 0' % reserved)
    pos = 20
    idents = []
    for _ in range(n_ident):
        (ln,) = struct.unpack_from('<I', b, pos)
        pos += 4
        chars = []
        for j in range(ln):
            raw = bytes(x ^ 0xB6 for x in b[pos + 4 * j:pos + 4 * j + 4])
            chars.append(chr(struct.unpack('<I', raw)[0]))
        pos += 4 * ln
        idents.append(''.join(chars))
    consts = []
    for _ in range(n_const):
        v, pos = decode_variant(b, pos)
        consts.append(v)
    lines = {}
    for _ in range(n_lines):
        tok, line = struct.unpack_from('<II', b, pos)
        pos += 8
        lines[tok] = line
    columns = {}
    for _ in range(n_lines):
        tok, col = struct.unpack_from('<II', b, pos)
        pos += 8
        columns[tok] = col
    if set(lines) != set(columns):
        raise ValueError('line and column tables index different tokens')
    tokens = []
    for _ in range(n_tokens):
        first = b[pos]
        if first & TOKEN_BYTE_MASK:
            (tk,) = struct.unpack_from('<I', b, pos)
            tk &= ~TOKEN_BYTE_MASK
            pos += 4
        else:
            tk = first
            pos += 1
        (end_line,) = struct.unpack_from('<I', b, pos)
        pos += 4
        ttype = tk & 0xFF
        payload = tk >> TOKEN_BITS
        if ttype >= T['TK_MAX']:
            raise ValueError('token type %d out of range' % ttype)
        if ttype in IDENT_PAYLOAD and payload >= n_ident:
            raise ValueError('identifier index out of range')
        if ttype in CONST_PAYLOAD and payload >= n_const:
            raise ValueError('constant index out of range')
        if ttype not in IDENT_PAYLOAD | CONST_PAYLOAD and payload:
            raise ValueError('payload on token %s' % TOKEN_NAMES[ttype])
        tokens.append((ttype, payload, end_line))
    if pos != len(b):
        raise ValueError('trailing %d bytes after token stream' % (len(b) - pos))
    for tok, line in lines.items():
        if tok >= n_tokens:
            raise ValueError('line table points past the token stream')
        if tokens[tok][2] < line:
            raise ValueError('token %d ends before the line it starts on' % tok)
    return {'version': version, 'compressed': bool(dsize), 'idents': idents,
            'consts': consts, 'lines': lines, 'columns': columns, 'tokens': tokens}


def bool_consts(gdc):
    """Top-level `const NAME [: TYPE] (= | :=) <bool literal>` on its own line.

    Top level = the `const` token starts a line at column 1 (the column
    table is what the reader turns into INDENT/DEDENT). The literal must be
    the last token of the statement: the next token starts a new line (or
    the stream ends), so `const X := false or Y` is not reported.
    """
    toks = gdc['tokens']
    starts = gdc['lines']
    cols = gdc['columns']
    n = len(toks)
    out = []
    for i, tok in enumerate(toks):
        if tok[0] != T['TK_CONST'] or i not in starts or cols[i] != 1:
            continue
        j = i + 1
        if j >= n or toks[j][0] != T['IDENTIFIER']:
            continue
        name = gdc['idents'][toks[j][1]]
        j += 1
        if j < n and toks[j][0] == T['COLON']:
            j += 1
            if j < n and toks[j][0] == T['IDENTIFIER']:  # explicit type, e.g. `: bool`
                j += 1
        if j >= n or toks[j][0] != T['EQUAL']:
            continue
        j += 1
        if j >= n or toks[j][0] != T['LITERAL']:
            continue
        val = gdc['consts'][toks[j][1]]
        if not isinstance(val, bool):
            continue
        if j + 1 < n and (j + 1) not in starts and toks[j + 1][0] != T['SEMICOLON']:
            continue  # an expression such as `false or X`, not a plain literal
        out.append({'const': name, 'live_value': val, 'line': starts[i]})
    return out


def script_res_path(entry_path):
    p = entry_path
    if p.startswith('res://'):
        p = p[len('res://'):]
    if p.endswith('.gdc'):
        p = p[:-4] + '.gd'
    return p


SRC_RE = re.compile(r'^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*bool\s*)?:?=\s*(true|false)\s*(?:#.*)?$')


def source_bool_consts(text):
    found = {}
    for line in text.splitlines():
        m = SRC_RE.match(line.rstrip())
        if m:
            found[m.group(1)] = m.group(2) == 'true'
    return found


def _source_reader(source_dir=None, git_repo=None, git_rev=None):
    if git_repo:
        import subprocess

        def read(rel):
            r = subprocess.run(['git', '-C', git_repo, 'show', '%s:godot/%s' % (git_rev or 'HEAD', rel)],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            return r.stdout.decode('utf-8') if r.returncode == 0 else None
        return read
    if source_dir:
        def read(rel):
            sp = os.path.join(source_dir, rel)
            if not os.path.exists(sp):
                return None
            with open(sp, encoding='utf-8') as fh:
                return fh.read()
        return read
    return None


def extract(pck_path, source_dir=None, git_repo=None, git_rev=None):
    reader = _source_reader(source_dir, git_repo, git_rev)
    pack = read_pck(pck_path)
    scripts = [e for e in pack['entries'] if e['path'].endswith('.gdc')]
    records = []
    stats = {'godot_version': pack['version'], 'pack_entries': len(pack['entries']),
             'gdc_scripts': len(scripts), 'tokenizer_versions': set(), 'compressed': 0}
    for e in sorted(scripts, key=lambda x: x['path']):
        gdc = decode_gdc(pck_file(pack, e))
        stats['tokenizer_versions'].add(gdc['version'])
        stats['compressed'] += int(gdc['compressed'])
        rel = script_res_path(e['path'])
        src = None
        if reader:
            text = reader(rel)
            src = None if text is None else source_bool_consts(text)
        for r in bool_consts(gdc):
            rec = {'file': 'godot/' + rel, 'const': r['const']}
            if reader:
                rec['source_default'] = None if src is None else src.get(r['const'])
            rec['live_value'] = r['live_value']
            rec['line'] = r['line']
            records.append(rec)
    stats['tokenizer_versions'] = sorted(stats['tokenizer_versions'])
    return pack, records, stats


# Flags that must be OFF in the live world (known-bad or unfinished), from
# the deploy pipeline notes. Checked against the pack, not assumed.
MUST_STAY_OFF = ['FP_RADIAL_DATUM', 'FP_CLOUDS', 'FP_PRECIP', 'FP_STORMS', 'FP_TIER_DEPTH_BIAS']


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('pck')
    ap.add_argument('--json', help='write records to this JSON file')
    ap.add_argument('--source-dir', help='res:// root of the source checkout (folder with project.godot)')
    ap.add_argument('--git-repo', help='read sources from this git repository instead of --source-dir')
    ap.add_argument('--git-rev', default='HEAD', help='revision for --git-repo (default HEAD)')
    ap.add_argument('--list', action='store_true', help='list pack entries and exit')
    ap.add_argument('--self-test', action='store_true', help='decode every script, print format checks')
    a = ap.parse_args(argv)
    if a.list:
        pack = read_pck(a.pck)
        for e in pack['entries']:
            print('%10d  %s' % (e['size'], e['path']))
        return 0
    pack, records, stats = extract(a.pck, a.source_dir, a.git_repo, a.git_rev)
    if a.self_test:
        print(json.dumps(stats, indent=2))
        cs = {r['const']: r['live_value'] for r in records if r['file'].endswith('cosmos/cube_sphere.gd')}
        rb = {r['const']: r['live_value'] for r in records if r['file'].endswith('net/remote_bridge.gd')}
        ok = all(cs.get(n) is False for n in MUST_STAY_OFF) and rb.get('CONTROL_ENABLED') is True
        for n in MUST_STAY_OFF:
            print('control %-22s live=%s (expect False)' % (n, cs.get(n)))
        print('control %-22s live=%s (expect True)' % ('CONTROL_ENABLED', rb.get('CONTROL_ENABLED')))
        print('self-test', 'PASS' if ok else 'FAIL')
        return 0 if ok else 1
    for r in records:
        sd = r.get('source_default', '')
        print('%-45s %-40s live=%-5s src=%s' % (r['file'], r['const'], r['live_value'], sd))
    print('# %d bool consts in %d scripts (Godot %s, tokenizer %s)' % (
        len(records), stats['gdc_scripts'], stats['godot_version'], stats['tokenizer_versions']),
        file=sys.stderr)
    if a.json:
        with open(a.pck, 'rb') as fh:
            pck_sha = hashlib.sha256(fh.read()).hexdigest()
        src_rev = None
        if a.git_repo:
            import subprocess
            src_rev = subprocess.run(['git', '-C', a.git_repo, 'rev-parse', a.git_rev],
                                     stdout=subprocess.PIPE).stdout.decode().strip() or None
        has_src = bool(a.git_repo or a.source_dir)
        flips = [r for r in records if r.get('source_default') is False and r['live_value']]
        doc = {
            'format': 'voxiverse-live-flags/1',
            'pack': {'name': os.path.basename(a.pck), 'sha256': pck_sha,
                     'godot_version': stats['godot_version'],
                     'gdscript_tokenizer_version': stats['tokenizer_versions'],
                     'scripts': stats['gdc_scripts']},
            'source_revision': src_rev,
            'counts': {
                'bool_consts_in_pack': len(records),
                'live_true': sum(1 for r in records if r['live_value']),
                'live_false': sum(1 for r in records if not r['live_value']),
                'flips_false_to_true': len(flips) if has_src else None,
                'flips_by_file': ({f: sum(1 for r in flips if r['file'] == f)
                                   for f in sorted({r['file'] for r in flips})} if has_src else None),
                'default_true_live_true': (sum(1 for r in records if r.get('source_default') is True
                                               and r['live_value']) if has_src else None),
                'live_differs_other': (sum(1 for r in records if r.get('source_default') is not None
                                           and r['source_default'] != r['live_value']) - len(flips)
                                       if has_src else None),
                'missing_in_source': (sum(1 for r in records if r.get('source_default') is None)
                                      if has_src else None),
            },
            'must_stay_off': MUST_STAY_OFF,
            'records': records,
        }
        with open(a.json, 'w', encoding='utf-8') as fh:
            json.dump(doc, fh, indent=1)
            fh.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
