#!/usr/bin/env python3
"""扫描 bash 源码:找出"函数最后一条语句可能返回非零"的位置。

`set -Eeuo pipefail` 下,若函数最后一条语句是 `[[ x ]] && cmd`,判定失败时函数返回 1,
调用处(不在 if/&&/|| 里)会让整个脚本中止 —— 这是本项目真机上踩过的坑,必须静态拦住。

用法: python3 tests/check-tail.py lib/*.sh bin/hermes-vps
退出码: 0 = 无风险;1 = 有风险(并列出)
"""
import re
import sys

RISKY_LAST = re.compile(r'^\s*(\[\[.*\]\]|\(\(.*\)\)|test\b.*)\s*&&\s*\S')
RISKY_PIPE = re.compile(r'\|\s*(head|grep\s+-q)\b')


def functions_of(lines):
    """返回 [(名字, 起始行, 结束行)] —— 基于花括号配平的粗粒度解析。"""
    starts = []
    for i, l in enumerate(lines):
        if re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{?\s*$', l) or re.match(
            r'^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{', l
        ):
            starts.append(i)
    out = []
    for s in starts:
        depth = 0
        seen = False
        end = len(lines) - 1
        for j in range(s, len(lines)):
            stripped = re.sub(r"'[^']*'", "", lines[j])
            stripped = re.sub(r'"[^"]*"', "", stripped)
            stripped = re.sub(r"#[^\"']*$", "", stripped)
            depth += stripped.count("{") - stripped.count("}")
            if "{" in stripped:
                seen = True
            if seen and depth <= 0:
                end = j
                break
        name = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)', lines[s]).group(1)
        out.append((name, s, end))
    return out


def main(paths):
    problems = []
    total = 0
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
        for name, s, e in functions_of(lines):
            total += 1
            body = [
                (i, l)
                for i, l in enumerate(lines[s + 1:e], start=s + 2)
                if l.strip() and not l.strip().startswith("#")
            ]
            if not body:
                continue
            i, last = body[-1]
            if last.rstrip().endswith("return 0") or last.rstrip().endswith("; fi") or last.rstrip().endswith("fi"):
                continue
            if RISKY_LAST.match(last):
                problems.append((path, i, name, last.strip()))
            elif RISKY_PIPE.search(last) and "||" not in last and "2>/dev/null" not in last:
                problems.append((path, i, name, last.strip()))
    print(f"  扫描函数 {total} 个")
    if not problems:
        print("  末尾语句风险:无")
        return 0
    print(f"  末尾语句风险:{len(problems)} 处")
    for path, i, name, last in problems:
        print(f"    {path}:{i} {name}()  →  {last[:88]}")
    return 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: check-tail.py <文件…>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
