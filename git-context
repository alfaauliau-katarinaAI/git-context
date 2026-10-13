#!/usr/bin/env python3
"""
git-context — Generate AI-friendly context for any git repo.
Dump project structure, git log, file contents, and branch topology
in one optimized prompt-ready block.

Usage:  git context [--depth N] [--files] [--log N] [--output file] [--dir <path>]
"""

import argparse
import json
import os
import subprocess
import sys
import fnmatch
from pathlib import Path
from datetime import datetime

DEFAULT_IGNORE = {
    '.git', 'node_modules', '.next', 'dist', 'build', 'target',
    '__pycache__', '.cache', 'venv', '.venv', '.env', 'env',
    '.tox', '.eggs', '*.egg-info', '.pytest_cache', '.mypy_cache',
    '.DS_Store', '.idea', '.vscode', '*.swp', '*.swo', '*~',
    '*.pyc', '*.pyo', '.coverage', 'coverage', '*.log',
    '.terraform', 'vendor', '.bundle',
}

def run(cmd, cwd=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd or os.getcwd(), timeout=10)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""

def size_fmt(n):
    if n > 1_000_000: return f"{n/1_000_000:.1f}MB"
    if n > 1_000: return f"{n/1_000:.0f}KB"
    return f"{n}B"

def should_ignore(name, ignored):
    for pat in ignored:
        if pat.startswith('*'):
            if name.endswith(pat[1:]): return True
        elif fnmatch.fnmatch(name, pat): return True
    return False

def tree(path, prefix="", ignored=DEFAULT_IGNORE, depth=3, current_depth=0):
    if current_depth > depth:
        return ""
    items = []
    try:
        entries = sorted(os.listdir(path))
    except PermissionError:
        return ""
    for e in entries:
        fp = os.path.join(path, e)
        if e.startswith('.') or should_ignore(e, ignored):
            continue
        is_dir = os.path.isdir(fp)
        items.append((e, fp, is_dir))
    result = ""
    for i, (name, fp, is_dir) in enumerate(items):
        is_last = i == len(items) - 1
        conn = "└── " if is_last else "├── "
        result += f"{prefix}{conn}{name}/\n" if is_dir else f"{prefix}{conn}{name}  ({size_fmt(os.path.getsize(fp))})\n"
        if is_dir:
            deeper = "    " if is_last else "│   "
            result += tree(fp, prefix + deeper, ignored, depth, current_depth + 1)
    return result

def file_contents(path, ignored=DEFAULT_IGNORE, max_total=15000):
    ext_map = {
        '.py': 'py', '.js': 'js', '.ts': 'ts', '.tsx': 'tsx', '.jsx': 'jsx',
        '.go': 'go', '.rs': 'rs', '.rb': 'rb', '.java': 'java', '.kt': 'kt',
        '.swift': 'swift', '.c': 'c', '.h': 'h', '.cpp': 'cpp', '.hpp': 'hpp',
        '.cs': 'cs', '.php': 'php', '.vue': 'vue', '.svelte': 'svelte',
        '.css': 'css', '.scss': 'scss', '.html': 'html', '.xml': 'xml',
        '.json': 'json', '.yaml': 'yaml', '.yml': 'yaml', '.toml': 'toml',
        '.md': 'md', '.txt': 'txt', '.sh': 'sh', '.bash': 'sh', '.zsh': 'sh',
        '.sql': 'sql', '.graphql': 'graphql', '.proto': 'proto',
        '.dockerfile': 'dockerfile', '.tf': 'tf', '.env': 'env',
        '.conf': 'conf', '.ini': 'ini', '.cfg': 'cfg',
    }
    snippet_exts = {'.py', '.js', '.ts', '.tsx', '.jsx', '.go', '.rs', '.rb',
                    '.java', '.kt', '.swift', '.c', '.h', '.cpp', '.cs', '.php',
                    '.vue', '.svelte', '.css', '.scss', '.html', '.xml',
                    '.json', '.yaml', '.yml', '.toml', '.md', '.sh', '.bash',
                    '.zsh', '.sql', '.graphql', '.proto', '.tf', '.conf', '.ini'}
    
    result = ""
    total = 0
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ignored and d != 'node_modules']
        for f in sorted(files):
            ext = os.path.splitext(f)[1].lower()
            if f.endswith('.min.js') or f.endswith('.min.css'):
                continue
            if ext not in snippet_exts:
                continue
            fp = os.path.join(root, f)
            try:
                content = Path(fp).read_text(encoding='utf-8', errors='replace')
                rel = os.path.relpath(fp, path)
                block = f"\n--- {rel} ---\n```{ext_map.get(ext, '')}\n{content.strip()}\n```\n"
                if total + len(block) > max_total:
                    remaining = max_total - total
                    result += block[:remaining] + f"\n... (truncated, more files in {rel})"
                    total = max_total
                    break
                result += block
                total += len(block)
            except Exception:
                continue
        if total >= max_total:
            break
    return result

def fmt_timestamp(ts):
    try:
        dt = datetime.fromisoformat(ts)
        return dt.strftime('%Y-%m-%d %H:%M')
    except:
        return ts[:19]

def main():
    p = argparse.ArgumentParser(description='Generate AI-friendly context for a git repo')
    p.add_argument('--depth', type=int, default=4, help='Directory tree depth (default: 4)')
    p.add_argument('--files', action='store_true', help='Include source file contents')
    p.add_argument('--log', type=int, default=20, help='Number of recent commits (default: 20, 0=skip)')
    p.add_argument('--output', '-o', help='Write to file instead of stdout')
    p.add_argument('--dir', default=os.getcwd(), help='Target directory (default: cwd)')
    p.add_argument('--json', action='store_true', help='Emit machine-readable JSON instead of Markdown')
    args = p.parse_args()

    target = os.path.abspath(args.dir)
    if not os.path.isdir(os.path.join(target, '.git')):
        print(f"❌ Not a git repo: {target}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        result = {
            "repo_name": os.path.basename(target),
            "generated": datetime.now().isoformat(timespec="seconds"),
            "path": target,
            "git": {
                "branch": run(["git", "rev-parse", "--abbrev-ref", "HEAD"], target),
                "remote": run(["git", "remote", "get-url", "origin"], target),
                "unstaged": run(["git", "diff", "--stat"], target),
                "staged": run(["git", "diff", "--cached", "--stat"], target),
            },
            "commits": run(["git", "log", f"--max-count={args.log}", "--oneline"], target).splitlines() if args.log > 0 else [],
            "branches": run(["git", "branch", "-a"], target).splitlines(),
            "tree": tree(target, ignored=DEFAULT_IGNORE, depth=args.depth),
        }
        if args.files:
            result["files"] = file_contents(target)
        output = json.dumps(result, ensure_ascii=False, indent=2)
        if args.output:
            Path(args.output).write_text(output + "\n", encoding="utf-8")
            print(f"Written to {args.output}", file=sys.stderr)
        else:
            print(output)
        return

    repo_name = os.path.basename(target)
    sections = []
    sections.append(f"# git-context: {repo_name}")
    sections.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    sections.append(f"Path: {target}")
    sections.append("")

    # Git info
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], target)
    remote = run(["git", "remote", "get-url", "origin"], target)
    sections.append(f"## Git Info\n- Branch: `{branch}`")
    sections.append(f"- Remote: {remote}")
    
    has_unstaged = run(["git", "diff", "--stat"], target)
    has_staged = run(["git", "diff", "--cached", "--stat"], target)
    status = ""
    if has_unstaged: status += f"\n- Unstaged changes: {has_unstaged.split(chr(10))[-1]}"
    if has_staged: status += f"\n- Staged changes: {has_staged.split(chr(10))[-1]}"
    if not has_unstaged and not has_staged:
        status += "\n- Working tree: clean"
    sections.append(status)

    # Recent commits
    if args.log > 0:
        log = run(["git", "log", f"--max-count={args.log}", "--oneline", "--graph",
                    "--pretty=format:%h %d %s (%an, %ar)"], target)
        if log:
            sections.append(f"\n## Recent Commits (last {args.log})")
            sections.append(f"```\n{log}\n```")

    # Branch topology
    branches = run(["git", "branch", "-a"], target)
    if branches:
        sections.append("\n## Branches")
        sections.append(f"```\n{branches}\n```")

    # Directory tree
    tree_out = tree(target, ignored=DEFAULT_IGNORE, depth=args.depth)
    sections.append(f"\n## Project Structure (depth={args.depth})")
    sections.append(f"```\n{tree_out}\n```")

    # File contents
    if args.files:
        contents = file_contents(target)
        if contents:
            sections.append("\n## File Contents")
            sections.append(contents)

    output = "\n".join(sections)
    
    if args.output:
        Path(args.output).write_text(output)
        print(f"✅ Written to {args.output}")
    else:
        print(output)

if __name__ == '__main__':
    main()
