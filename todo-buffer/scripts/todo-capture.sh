#!/usr/bin/env bash
# todo-buffer fast-path capture hook for Claude Code UserPromptSubmit.
# Reads JSON on stdin, writes JSON on stdout. On a `todo:` / `todo!` prompt,
# intercepts it, appends to ~/.claude/todo-buffer/todos.md, and blocks the
# model. Non-matching prompts pass through untouched.
#
# Duplicate detection is project-scoped:
#   - `todo: X` in repo `foo` is compared only against buffered lines that
#     have a `[foo]` tag. `todo! X` is compared only against lines without
#     a project tag. Same text in a different project = two entries.
#   - Exact text match in scope  -> block, "Steht schon drin".
#   - Similar (Jaccard >= 0.7)   -> don't write; hand off to the skill via
#     additionalContext so the model can show the candidate and ask the
#     user whether it's the same todo.
#   - No match                   -> append + confirmation, fast path.

set -u

# Soft dependencies: if any required tool is missing, exit silently so the
# Claude Code model picks up the prompt and the skill handles it as a fallback.
# This keeps the plugin usable on systems where `jq` isn't installed (common
# on vanilla Git Bash / Windows) — capture still works, just not instant.
for dep in jq awk; do
    command -v "$dep" >/dev/null 2>&1 || exit 0
done

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
[ -z "$text" ] && exit 0

buffer_dir="$HOME/.claude/todo-buffer"
buffer="$buffer_dir/todos.md"
aliases_file="$buffer_dir/project-aliases.json"
mkdir -p "$buffer_dir"
touch "$buffer"

project=""
if [ "$marker" = ":" ]; then
    if gitroot=$(git rev-parse --show-toplevel 2>/dev/null); then
        project=$(basename "$gitroot")
    else
        # Keys in aliases.json are prefixed with "cwd:" to avoid MSYS path
        # translation on Git Bash (which would turn /tmp/foo into a Windows path).
        alias_status="missing"
        alias_value=""
        if [ -f "$aliases_file" ]; then
            alias_value=$(TODO_PWD_KEY="cwd:$PWD" jq -r 'if has(env.TODO_PWD_KEY) then .[env.TODO_PWD_KEY] else "__MISSING__" end' "$aliases_file" 2>/dev/null)
            if [ "$alias_value" != "__MISSING__" ]; then
                alias_status="found"
            fi
        fi

        if [ "$alias_status" = "missing" ]; then
            dir_basename=$(basename "$PWD")
            context=$(printf 'Der todo-buffer capture-hook wurde in einem Verzeichnis ohne Git-Repo aufgerufen, und es gibt noch keinen gespeicherten Projekt-Alias für diesen Ordner.\n\ncwd: %s\nbasename: %s\ntext: "%s"\n\nWICHTIG: Das Todo wurde NOCH NICHT gespeichert. Bitte jetzt den Non-git-capture-Flow aus dem todo-buffer-Skill ausführen:\n1. Frage den User, ob der Ordnername "%s" als Projekt-Tag genutzt werden soll, ob ein anderer Name gewünscht ist, oder ob das Todo global (ohne Tag) gespeichert werden soll.\n2. Schreibe den gewählten Eintrag in ~/.claude/todo-buffer/todos.md (`[YYYY-MM-DD HH:MM] [<tag>] <text>` bzw. ohne Tag).\n3. Speichere das Mapping mit Key "cwd:%s" -> <tag> (leerer String für global) in ~/.claude/todo-buffer/project-aliases.json (das `cwd:` Präfix ist wichtig, es verhindert Path-Translation in Git Bash). Lies die Datei (falls nicht vorhanden: starte mit `{}`), füge den Key hinzu, schreib zurück — Edit/Write reicht, jq ist nicht erforderlich. Vorhandene Keys nicht überschreiben.\n4. Bestätige normal ("Gespeichert in <proj> ..." oder "Gespeichert ohne Projekt-Ref ...").' \
                "$PWD" "$dir_basename" "$text" "$dir_basename" "$PWD" "$PWD")
            jq -nc --arg ctx "$context" \
                '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
            exit 0
        fi

        project="$alias_value"
    fi
fi

result=$(awk -v needle="$text" -v needle_project="$project" '
function normalize(s,   r, i, c) {
    r = ""
    for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        if (c ~ /[a-z0-9]/) r = r c
        else r = r " "
    }
    gsub(/  +/, " ", r)
    gsub(/^ | $/, "", r)
    return r
}
function tokenize(s, arr,   temp, n, i) {
    for (k in arr) delete arr[k]
    n = split(s, temp, " ")
    for (i = 1; i <= n; i++) if (temp[i] != "") arr[temp[i]] = 1
}
function count_tokens(arr,   n, t) { n = 0; for (t in arr) n++; return n }
function jaccard(a, b,   inter, uni, t) {
    inter = 0; uni = 0
    for (t in a) { uni++; if (t in b) inter++ }
    for (t in b) if (!(t in a)) uni++
    return (uni == 0) ? 0 : inter / uni
}
BEGIN {
    tokenize(normalize(needle), needle_tokens)
    needle_n = count_tokens(needle_tokens)
    best_score = 0; best_line = ""; best_exact = 0
}
/^\[[0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+\]/ {
    pe = index($0, "] ")
    rest = substr($0, pe + 2)
    line_project = ""
    if (rest ~ /^\[[^][]+\] /) {
        pe2 = index(rest, "] ")
        line_project = substr(rest, 2, pe2 - 2)
        line_text = substr(rest, pe2 + 2)
    } else {
        line_text = rest
    }
    sub(/[ \t]+$/, "", line_text)

    if (line_project != needle_project) next

    if (line_text == needle) {
        best_exact = 1
        best_line = $0
        exit
    }

    tokenize(normalize(line_text), cand_tokens)
    cand_n = count_tokens(cand_tokens)
    if (needle_n >= 3 && cand_n >= 3) {
        score = jaccard(needle_tokens, cand_tokens)
        if (score > best_score) { best_score = score; best_line = $0 }
    }
}
END {
    if (best_exact)            printf "exact\t%s\n", best_line
    else if (best_score >= 0.7) printf "similar\t%s\t%.2f\n", best_line, best_score
    else                        print  "none"
}
' "$buffer")

status=$(printf '%s' "$result" | cut -f1)

case "$status" in
    exact)
        jq -nc --arg msg "Steht schon drin, nichts geändert." \
            '{decision:"block", reason:$msg, systemMessage:$msg, continue:false, stopReason:$msg, suppressOutput:false}'
        exit 0
        ;;
    similar)
        match_line=$(printf '%s' "$result" | cut -f2)
        score=$(printf '%s' "$result" | cut -f3)
        scope_label=""
        if [ -n "$project" ]; then scope_label="im Projekt $project"; else scope_label="im globalen Scope (ohne Projekt-Tag)"; fi
        context=$(printf 'Der todo-buffer capture-hook hat einen ähnlichen bereits vorhandenen Eintrag %s gefunden (Jaccard-Score %s):\n\n  %s\n\nUser hat gerade versucht zu capturen: "%s"\n\nWICHTIG: Das neue Todo wurde NOCH NICHT gespeichert. Bitte jetzt den Capture-Similarity-Flow aus dem todo-buffer-Skill ausführen: zeige den Kandidaten, frage ob es dasselbe Todo ist (dann nichts eintragen), oder ob trotzdem eingetragen werden soll (dann Timestamp holen und die Zeile anhängen: `[YYYY-MM-DD HH:MM] %s%s`).' \
            "$scope_label" "$score" "$match_line" "$text" "$( [ -n "$project" ] && printf '[%s] ' "$project" )" "$text")
        jq -nc --arg ctx "$context" \
            '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
        exit 0
        ;;
esac

if [ -s "$buffer" ] && [ "$(tail -c 1 "$buffer")" != $'\n' ]; then
    printf '\n' >> "$buffer"
fi
timestamp=$(date +"%Y-%m-%d %H:%M")
if [ -n "$project" ]; then project_tag="[${project}] "; else project_tag=""; fi
printf '[%s] %s%s\n' "$timestamp" "$project_tag" "$text" >> "$buffer"

count=$(grep -c "^\[" "$buffer" 2>/dev/null || printf 0)
if [ -n "$project" ]; then
    msg="Gespeichert in ${project} (${count} Todos im Puffer)."
else
    msg="Gespeichert ohne Projekt-Ref (${count} Todos im Puffer)."
fi

jq -nc --arg msg "$msg" \
    '{decision:"block", reason:$msg, systemMessage:$msg, continue:false, stopReason:$msg, suppressOutput:false}'
exit 0
