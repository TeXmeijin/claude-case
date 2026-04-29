#!/usr/bin/env bash
# case-guard: a Claude Code Stop hook that detects when the assistant is about
# to ask the user to choose between multiple options in plain chat, and tells
# Claude to use the `case` skill instead.
#
# Two-stage judgment:
#   1. Cheap regex prefilter — only messages with 2+ list items in the tail
#      are passed on. Statements/paragraphs/code-only messages skip everything.
#   2. Claude Haiku via `claude -p` makes the final BLOCK/PASS call. The hook
#      blocks only on an explicit BLOCK verdict; any error or uncertainty
#      defaults to PASS (fail-open).
#
# Wire into settings.json as a Stop hook (type: command). The script reads the
# Stop hook payload from stdin and emits `{decision:"block", reason:"..."}` on
# stdout when Haiku confirms a multi-choice prompt to the user.
#
# Override the log directory with $CASE_GUARD_LOG_DIR. Defaults to
# $CLAUDE_CONFIG_DIR/case-guard or $HOME/.claude/case-guard.

set -u

# Recursion guard. The script invokes `claude -p` for the LLM verdict, which
# spawns an inner Claude Code session whose Stop hook would re-run this script
# with the Haiku reply as input. Exit immediately when re-entered.
if [ "${CASE_GUARD_INSIDE:-0}" = "1" ]; then
  exit 0
fi

# meijin uses Max Plan and explicitly does not want hook calls to take the
# API-key billing path. Force OAuth by clearing the env var if present.
unset ANTHROPIC_API_KEY

payload=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  exit 0
fi

active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)
msg=$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""' 2>/dev/null)

# Avoid infinite loops: if Claude already continued because of a Stop block,
# don't block again.
if [ "$active" = "true" ]; then
  exit 0
fi

if [ -z "$msg" ]; then
  exit 0
fi

# Self-reference skips. Cheap filter that prevents the hook from firing on
# messages discussing the hook itself or the case skill — those messages look
# list-like but are not user-facing choice prompts.
if printf '%s' "$msg" | grep -Eqi 'case skill|`case`|/case[[:space:]]|/case$|decide\.py|Decision result saved'; then
  exit 0
fi
if printf '%s' "$msg" | grep -Eqi 'case-guard|stop_hook_active|Stop hook|choose among multiple options|Build the case input|誤検知|false positive'; then
  exit 0
fi

# Strip fenced code blocks so numbered lists inside code don't trigger.
stripped=$(printf '%s' "$msg" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=1-f; next} !f{print}')

# Only inspect the tail of the message — choices to the user usually sit at the end.
tail_msg=$(printf '%s\n' "$stripped" | tail -n 30)

numbered=$(printf '%s\n' "$tail_msg" | grep -Ec '^[[:space:]]*([0-9]+[.)]|[A-Z][.)])[[:space:]]+.+' || true)
bullet=$(printf '%s\n' "$tail_msg" | grep -Ec '^[[:space:]]*[-*][[:space:]]+.+' || true)

log_dir="${CASE_GUARD_LOG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/case-guard}"
mkdir -p "$log_dir" 2>/dev/null || true

log_event() {
  if [ -d "$log_dir" ]; then
    printf '%s\n' "$1" >> "$log_dir/decisions.jsonl" 2>/dev/null || true
  fi
}

# Loose prefilter: a multi-choice prompt to the user requires at least 2
# enumerated items in the tail. Anything below that can't be multi-choice and
# skips the LLM call entirely.
if [ "${numbered:-0}" -lt 2 ] && [ "${bullet:-0}" -lt 2 ]; then
  ts=$(date -u +%FT%TZ)
  log_event "$(jq -nc \
    --arg ts "$ts" \
    --argjson numbered "${numbered:-0}" \
    --argjson bullet "${bullet:-0}" \
    '{ts:$ts, stage:"prefilter", numbered:$numbered, bullet:$bullet, blocked:false}')"
  exit 0
fi

# Candidate. Ask Haiku for the final verdict.
#
# CRITICAL: Haiku must classify the wrapped message, not respond to it. If the
# message contains a question, Haiku tends to answer the question instead of
# labeling it. The system prompt and the wrapping tags below both reinforce
# "label only, do not engage with content".
classifier='<role>You are a strict text classifier. The user content you receive is wrapped in <assistant_message_to_classify> tags and contains a snippet of an assistant'\''s chat reply. You must LABEL it. Do NOT answer questions inside it, do NOT continue the conversation, do NOT generate code, do NOT explain anything outside the required label format.</role>

<task>Decide whether the wrapped assistant message is asking the human to PICK among multiple options in plain chat — in which case a structured `case` skill should be used instead of inline enumeration.</task>

<output_format>
Line 1: exactly one token, BLOCK or PASS (uppercase).
Line 2: a brief reason under 100 characters.
No other output. No code fences. No follow-up questions.
</output_format>

<labels>
BLOCK = the message ENDS by asking the user to choose among 2+ listed options.
  Examples:
    - "どっちにしますか？\n1. 削除\n2. 残す"
    - "Which approach? Option A or B?"
    - "案 A・B・C のどれで進めますか？"

PASS = anything else, including:
    - Recommending one option after listing alternatives.
    - Explaining or describing options without asking the user to pick.
    - Discussing this hook or the `case` skill itself.
    - Listing steps, items, examples, file changes, or status.
    - A single yes/no confirmation.
    - Uncertain cases (default to PASS).
</labels>'

wrapped_msg=$(printf '<assistant_message_to_classify>\n%s\n</assistant_message_to_classify>' "$msg")

llm_output=$(printf '%s' "$wrapped_msg" | CASE_GUARD_INSIDE=1 claude -p \
  --model claude-haiku-4-5-20251001 \
  --append-system-prompt "$classifier" \
  2>/dev/null || true)

verdict=$(printf '%s\n' "$llm_output" | head -n 1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
llm_reason=$(printf '%s\n' "$llm_output" | sed -n '2,3p' | tr '\n' ' ' | head -c 200)

ts=$(date -u +%FT%TZ)

if [ "$verdict" != "block" ]; then
  log_event "$(jq -nc \
    --arg ts "$ts" \
    --argjson numbered "${numbered:-0}" \
    --argjson bullet "${bullet:-0}" \
    --arg verdict "${verdict:-}" \
    --arg llm_reason "$llm_reason" \
    '{ts:$ts, stage:"llm", numbered:$numbered, bullet:$bullet, verdict:$verdict, llm_reason:$llm_reason, blocked:false}')"
  exit 0
fi

log_event "$(jq -nc \
  --arg ts "$ts" \
  --argjson numbered "${numbered:-0}" \
  --argjson bullet "${bullet:-0}" \
  --arg verdict "$verdict" \
  --arg llm_reason "$llm_reason" \
  '{ts:$ts, stage:"llm", numbered:$numbered, bullet:$bullet, verdict:$verdict, llm_reason:$llm_reason, blocked:true}')"

reason='You are about to ask the user to choose among multiple options in plain chat.

Use the installed `case` skill instead of enumerating options in the assistant response.

Required:
1. Build the case input JSON with questions, options, and exactly one recommended option per question.
2. Run python3 on the skill'\''s decide.py (in the background) with --output set to a temp path.
3. Wait for the browser submission, then read the result JSON and continue based on the structured answer.

Do not ask the user to reply with "1", "2", "A/B", or similar plain-text choices.'

jq -n --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
