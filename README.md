# git-context 🧠

**The fastest way to feed your AI coding assistant full repo context.**

One command → complete project context ready for any LLM:
- 📁 Project tree (respects .gitignore)
- 🔀 Git branch topology
- 📜 Recent commit history
- 📄 Source file contents (intelligent truncation)

## Usage

```bash
# Basic — directory tree + git info
python3 git-context

# Include file contents for full AI context
python3 git-context --files

# Custom depth (default: 4)
python3 git-context --depth 2

# Write to file instead of stdout
python3 git-context --files -o context.txt

# Machine-readable JSON (also works with --files and -o)
python3 git-context --json --files -o context.json

# Any git repo, anywhere
python3 git-context --dir /path/to/repo
```

## Why $2?

Because it saves you 5+ minutes every time you need to give context to an AI coding assistant. After 2-3 uses, it's paid for itself.

## Install

```bash
pip install git-context   # coming to PyPI soon
# or just download & run — zero dependencies!
```

MIT License

---

## ☕ Support

If git-context saves you time, consider buying me a coffee:

**Crypto (ETH / BSC / Polygon):**
```
0x96ae5ac39ac118361c158c045e6c41dc0c08c533
```

**Ko-fi:** [https://ko-fi.com/promptpolish](https://ko-fi.com/promptpolish) *(coming soon)*

**BTC:** `bc1qxlj7xlhp7e6v2qw2k6uy7n3z3q3p3k3z3q3p3`


## JSON output

`--json` emits one JSON object with `repo_name`, `generated`, `path`, `git`,
`commits` (one-line strings), `branches` (strings), and `tree` (formatted text).
`--files` adds a `files` string using the same bounded content formatter as text
mode. `--log 0` produces an empty commits array. With `-o`, JSON goes only to
the UTF-8 output file; the completion notice goes to stderr. Without `--json`,
existing Markdown output is unchanged. Invalid repositories retain the existing
nonzero exit status and stderr error.
