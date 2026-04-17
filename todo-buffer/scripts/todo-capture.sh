#!/usr/bin/env bash
# todo-buffer fast-path: intercept "todo:" / "todo!" prompts and capture
# without involving the model. Speaks Claude Code's UserPromptSubmit hook
# protocol: reads JSON on stdin, emits JSON on stdout.
#
# On match: append to the buffer, print a confirmation via systemMessage,
# and set continue=false so the model isn't invoked.
# On non-match: print nothing, exit 0 → model handles the prompt as usual.

set -u

payload=$(cat)
prompt=$(printf '%s' "$payload" | jq -r '.prompt // .user_prompt // empty' 2>/dev/null)
[ -z "$prompt" ] && exit 0

shopt -s nocasematch
if [[ "$prompt" =~ ^[[:space:]]*todo([:!])[[:space:]]*(.*) ]]; then
    marker="${BASH_REMATCH[1]}"
    text="${BASH_REMATCH[2]}"
else
    exit 0
fi
shopt -u nocasematch

text="${text#"${text%%[![:space:]]*}"}"
text="${text%"${text##*[![:space:]]}"}"

if [ -z "$text" ]; then
    exit 0
fi

project_tag=""
pname=""
if [ "$marker" = ":" ]; then
    if gitroot=$(git rev-parse --show-toplevel 2>/dev/null); then
        pname=$(basename "$gitroot")
        project_tag="[${pname}] "
    fi
fi

buffer_dir="$HOME/.claude/todo-buffer"
buffer="$buffer_dir/todos.md"
mkdir -p "$buffer_dir"
touch "$buffer"

if awk -v needle=" ${text}" '
    length($0) >= length(needle) && substr($0, length($0)-length(needle)+1) == needle { found=1; exit }
    END { exit (found ? 0 : 1) }
' "$buffer"; then
    jq -nc --arg msg "Steht schon drin, nichts geändert." \
        '{decision: "block", reason: $msg, systemMessage: $msg, continue: false, stopReason: $msg, suppressOutput: false}'
    exit 0
fi

timestamp=$(date +"%Y-%m-%d %H:%M")
if [ -s "$buffer" ] && [ "$(tail -c 1 "$buffer")" != $'\n' ]; then
    printf '\n' >> "$buffer"
fi
printf '[%s] %s%s\n' "$timestamp" "$project_tag" "$text" >> "$buffer"

count=$(grep -c "^\[" "$buffer" 2>/dev/null || printf 0)

if [ -n "$project_tag" ]; then
    msg="Gespeichert in ${pname} (${count} Todos im Puffer)."
else
    msg="Gespeichert ohne Projekt-Ref (${count} Todos im Puffer)."
fi

jq -nc --arg msg "$msg" \
    '{decision: "block", reason: $msg, systemMessage: $msg, continue: false, stopReason: $msg, suppressOutput: false}'
exit 0
