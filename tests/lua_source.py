"""A small Lua 5.4 source scanner for the static tests (no dependency).

tokens(src) yields (kind, value, line, start) for 'string' literals (value decoded), 'comment' and
'code' runs; code_only(src) returns the source with every comment and string literal blanked out
(newlines kept, so line numbers stay valid). Long brackets ([[...]], [==[...]==]) are handled for
both strings and comments.
"""
import re
from pathlib import Path

RESOURCE = Path(__file__).resolve().parent.parent
LUA_DIRS = ('config', 'shared', 'client', 'server')

_LONG = re.compile(r'\[(=*)\[')
_ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', '"': '"', "'": "'", 'a': '\a', 'b': '\b',
            'f': '\f', 'v': '\v', '\n': '\n'}


def tokens(src):
    i, n, line = 0, len(src), 1
    code_start = 0
    while i < n:
        c = src[i]
        if c == '-' and src.startswith('--', i):
            if code_start < i:
                yield 'code', src[code_start:i], line - src.count('\n', code_start, i), code_start
            start, start_line = i, line
            m = _LONG.match(src, i + 2)
            if m:
                close = ']' + m.group(1) + ']'
                end = src.find(close, m.end())
                end = n if end < 0 else end + len(close)
            else:
                end = src.find('\n', i)
                end = n if end < 0 else end
            line += src.count('\n', start, end)
            yield 'comment', src[start:end], start_line, start
            i = code_start = end
            continue
        m = _LONG.match(src, i) if c == '[' else None
        if m or c in '"\'':
            if code_start < i:
                yield 'code', src[code_start:i], line - src.count('\n', code_start, i), code_start
            start, start_line = i, line
            if m:
                close = ']' + m.group(1) + ']'
                end = src.find(close, m.end())
                end = n if end < 0 else end
                value = src[m.end():end]
                if value.startswith('\n'):
                    value = value[1:]
                end += len(close)
            else:
                j, buf = i + 1, []
                while j < n and src[j] != c and src[j] != '\n':
                    if src[j] == '\\' and j + 1 < n:
                        nx = src[j + 1]
                        if nx in _ESCAPES:
                            buf.append(_ESCAPES[nx]); j += 2
                        elif nx.isdigit():
                            d = re.match(r'\d{1,3}', src[j + 1:]).group(0)
                            buf.append(chr(int(d))); j += 1 + len(d)
                        elif nx == 'x':
                            buf.append(chr(int(src[j + 2:j + 4], 16))); j += 4
                        elif nx == 'z':
                            j += 2
                            while j < n and src[j].isspace():
                                j += 1
                        elif nx == 'u':
                            close_brace = src.index('}', j)
                            buf.append(chr(int(src[j + 3:close_brace], 16))); j = close_brace + 1
                        else:
                            buf.append(nx); j += 2
                        continue
                    buf.append(src[j]); j += 1
                value, end = ''.join(buf), j + 1
            line += src.count('\n', start, end)
            yield 'string', value, start_line, start
            i = code_start = end
            continue
        if c == '\n':
            line += 1
        i += 1
    if code_start < n:
        yield 'code', src[code_start:], line - src.count('\n', code_start, n), code_start


def code_only(src, keep_strings=False):
    """The source with comments (and string literals unless keep_strings) replaced by spaces."""
    out = []
    for kind, value, _, start in tokens(src):
        if kind == 'code':
            out.append(value)
            continue
        raw_end = start + (len(value) if kind == 'comment' else 0)
        if kind == 'string':
            raw = _raw_string(src, start)
            if keep_strings:
                out.append(raw)
                continue
            out.append('""' + ''.join('\n' if ch == '\n' else ' ' for ch in raw[2:]))
            continue
        out.append(''.join('\n' if ch == '\n' else ' ' for ch in src[start:raw_end]))
    return ''.join(out)


def _raw_string(src, start):
    m = _LONG.match(src, start)
    if m:
        close = ']' + m.group(1) + ']'
        end = src.find(close, m.end())
        return src[start:(len(src) if end < 0 else end + len(close))]
    q, j = src[start], start + 1
    while j < len(src) and src[j] != q and src[j] != '\n':
        j += 2 if src[j] == '\\' else 1
    return src[start:j + 1]


def lua_files(dirs=LUA_DIRS, root=RESOURCE):
    for d in dirs:
        yield from sorted((root / d).rglob('*.lua'))


def read(path):
    return Path(path).read_text(encoding='utf-8-sig')
