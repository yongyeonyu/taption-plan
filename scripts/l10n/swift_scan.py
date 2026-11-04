"""Swift 소스에서 문자열 리터럴이 들어간 호출을 읽는 작은 스캐너."""
from __future__ import annotations
import re
from dataclasses import dataclass, field


@dataclass
class Literal:
    template: str
    expressions: list[str] = field(default_factory=list)
    start: int = 0
    end: int = 0


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def skip_trivia(src: str, i: int) -> int:
    while i < len(src):
        if src[i].isspace():
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = len(src) if j < 0 else j + 1
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            i = len(src) if j < 0 else j + 2
        else:
            break
    return i


def read_interpolation(src: str, i: int) -> tuple[str, int]:
    """`\\(` 다음부터 닫는 괄호까지 읽는다. 안쪽 문자열은 건너뛴다."""
    start, depth = i, 1
    while i < len(src) and depth:
        c = src[i]
        if c == '"':
            i = read_literal(src, i).end
            continue
        depth += c == "("
        depth -= c == ")"
        i += 1
    return src[start : i - 1], i


def read_literal(src: str, i: int) -> Literal:
    start = i
    multi = src.startswith('"""', i)
    i += 3 if multi else 1
    out, exprs = [], []
    while i < len(src):
        c = src[i]
        if c == "\\":
            n = src[i + 1]
            if n == "(":
                expr, i = read_interpolation(src, i + 2)
                out.append("{%d}" % len(exprs))
                exprs.append(expr.strip())
                continue
            if n == "u":
                j = src.index("}", i)
                out.append(chr(int(src[i + 3 : j], 16)))
                i = j + 1
                continue
            out.append(ESCAPES.get(n, n))
            i += 2
            continue
        if multi and src.startswith('"""', i):
            i += 3
            break
        if not multi and c == '"':
            i += 1
            break
        if not multi and c == "\n":
            break
        out.append(c)
        i += 1
    text = "".join(out)
    if multi:
        text = text.split("\n", 1)[-1].rsplit("\n", 1)[0] if "\n" in text else text
    return Literal(text, exprs, start, i)


def read_argument(src: str, i: int) -> tuple[Literal | None, str, int]:
    """호출 인자 하나를 읽는다. 온전한 리터럴이면 그것을, 아니면 None과 원문을 준다."""
    i = skip_trivia(src, i)
    label = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\s*:\s*").match(src, i)
    if label:
        i = skip_trivia(src, label.end())
    start, depth, lit = i, 0, None
    only_literal = src[i:i + 1] == '"'
    while i < len(src):
        i2 = skip_trivia(src, i)
        i = i2
        c = src[i]
        if c == '"':
            value = read_literal(src, i)
            if i == start:
                lit = value
            i = value.end
            continue
        if depth == 0 and c in ",)":
            break
        depth += c in "([{"
        depth -= c in ")]}"
        i += 1
    raw = src[start:i].strip()
    if not (only_literal and lit is not None and src[lit.end:i].strip() == ""):
        lit = None
    return lit, raw, i


@dataclass
class Call:
    name: str
    offset: int
    ko: Literal | None
    en: Literal | None
    raw: tuple[str, str]
    extra: bool


CALL = re.compile(r"(?:\b|\.)([A-Za-z_][A-Za-z0-9_]*)\(")


def calls_in(src: str, names: set[str] | None = None):
    """코드와 문자열 보간 안쪽까지 훑어 두 인자 호출을 돌려준다."""
    pending = [(src, 0)]
    while pending:
        text, base = pending.pop()
        i = 0
        while i < len(text):
            j = skip_trivia(text, i)
            if j != i:
                i = j
                continue
            if text[i] == '"':
                lit = read_literal(text, i)
                for expr in lit.expressions:
                    pending.append((expr, base + i))
                i = lit.end
                continue
            m = CALL.match(text, i)
            if m and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
                name = m.group(1)
                after = m.end()
                first = re.compile(r"\s*(?:[A-Za-z_]+\s*:\s*)?\"").match(text, after)
                if name in (names or ()) or first:
                    try:
                        a, ra, p = read_argument(text, after)
                        if text[p:p + 1] == ",":
                            b, rb, q = read_argument(text, p + 1)
                            yield Call(name, base + i, a, b, (ra, rb), text[q:q + 1] == ",")
                    except (IndexError, ValueError):
                        pass
                i = after
                continue
            i += 1


def line_of(src: str, offset: int) -> int:
    return src.count("\n", 0, offset) + 1
