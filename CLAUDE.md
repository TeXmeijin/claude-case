# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single Claude Code skill, `case` (slash command `/case`, repo `claude-case`), that replaces enumerated multi-choice prompts ("1. X? 2. Y? 3. Z?") with a local browser UI. The skill follows the same blocking pattern as `crit`: launch a Python server in the background, the user submits in the browser, a result JSON is written, the agent reads it.

Everything the skill needs lives in `skills/case/`:

| File            | Role                                                                                  |
| --------------- | ------------------------------------------------------------------------------------- |
| `SKILL.md`      | Agent-facing contract (frontmatter `description` is the trigger prompt; body is usage) |
| `decide.py`     | stdlib-only HTTP server; renders `template.html`, POSTs `/submit` → writes result JSON |
| `template.html` | Single-file UI (inline CSS + JS); contains the `__DECIDE_DATA__` placeholder          |
| `sample.json`   | Example input used for local testing                                                  |

## How the pieces fit

`decide.py` reads `template.html` verbatim and does a plain `str.replace("__DECIDE_DATA__", json.dumps(data))` before serving it. The browser-side JS then reads `window.DECIDE_DATA` (injected at that placeholder) to render questions. Consequences:

- **Do not introduce a second placeholder or any other templating.** The substitution is a single literal replace on a token that must not appear elsewhere in the HTML.
- **Input/output schema is defined in three places** — `SKILL.md` (agent contract), `template.html` (`buildResult()` in the `<script>` block), and the README examples. A schema change requires updating all three.
- **The server is single-shot.** It waits on one `/submit` POST, then shuts down. No auth, no CORS — it binds `127.0.0.1` on a random free port.
- **Result file is the handoff.** `decide.py` prints `Decision result saved to <path>` to stdout; the skill instructions tell the agent to read that path. Do not change that stdout line without updating `SKILL.md` Step 3.

## Common commands

```bash
# Run locally with the bundled sample
python3 skills/case/decide.py skills/case/sample.json

# Run with a custom input and explicit output path
python3 skills/case/decide.py /tmp/input.json --output /tmp/result.json

# Skip auto-opening the browser (useful when iterating on HTML/CSS)
python3 skills/case/decide.py skills/case/sample.json --no-open

# Install this working copy as a user-scope skill for Claude Code
gh skill install ./ case --from-local --agent claude-code --scope user --force
```

No build step, no package manager, no tests — Python stdlib only. Runtime dep: Python 3 (for `http.server`, `webbrowser`, `socket`).

## When editing the skill

- **`SKILL.md` frontmatter `description`** is what Claude Code matches against to trigger the skill. Both the English TRIGGER phrases and the Japanese トリガー list are load-bearing — changes here change invocation behavior. The SKIP clause is equally important (prevents firing on simple yes/no).
- **`allowed-tools`** in frontmatter is `Bash(python3:*), Read, Write` — adding tools widens the skill's permissions, so keep it minimal.
- **UI changes to `template.html`** should be verified by running `decide.py` with `sample.json` and clicking through — there is no other test harness. Keep the file self-contained (no external CSS/JS fetches); the server only serves `/` and `/submit`.
- **Keyboard shortcuts** are documented in both `README.md` and `SKILL.md` — keep them in sync with the `keydown` handler at the bottom of `template.html`.

## Install path for end users

`gh skill install TeXmeijin/claude-case case --agent claude-code --scope user` drops the skill at `~/.claude/skills/case/`. The `SKILL.md` Step 2 command hard-codes that path (`python3 ~/.claude/skills/case/decide.py …`); if the install layout changes, update that line too.
