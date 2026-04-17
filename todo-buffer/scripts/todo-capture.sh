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

buffer_dir="$HOME/.claude/todo-buffer"
buffer="$buffer_dir/todos.md"
aliases_file="$buffer_dir/project-aliases.json"
mkdir -p "$buffer_dir"
touch "$buffer"

# --- Scope detection (shared by list + capture) ---
# Sets: scope_mode = "project" | "global" | "all" (unknown dir)
#       scope_project = "<name>" or ""
# Emit a blocking message. Claude Code renders the content from `stopReason`,
# prefixed with "Operation stopped by hook:" — we can't suppress that prefix
# without giving up the block (then the model runs, defeating the fast path).
# A leading blank line in the payload gives visual breathing room between the
# prefix and our header.
emit_block() {
    local msg
    msg=$'\n\n'"$1"
    jq -nc --arg msg "$msg" \
        '{decision:"block", reason:$msg, systemMessage:$msg, continue:false, stopReason:$msg, suppressOutput:false}'
}

detect_scope() {
    scope_mode="all"
    scope_project=""
    if gitroot=$(git rev-parse --show-toplevel 2>/dev/null); then
        scope_mode="project"
        scope_project=$(basename "$gitroot")
        return
    fi
    if [ -f "$aliases_file" ]; then
        alias_value=$(TODO_PWD_KEY="cwd:$PWD" jq -r 'if has(env.TODO_PWD_KEY) then .[env.TODO_PWD_KEY] else "__MISSING__" end' "$aliases_file" 2>/dev/null)
        if [ "$alias_value" != "__MISSING__" ]; then
            if [ -z "$alias_value" ]; then
                scope_mode="global"
            else
                scope_mode="project"
                scope_project="$alias_value"
            fi
        fi
    fi
}

shopt -s nocasematch

# --- Dispatch: `todos?` [arg] -> list; `todo:` / `todo!` -> capture; else passthrough ---
if [[ "$prompt" =~ ^[[:space:]]*todos[?][[:space:]]*(.*)$ ]]; then
    shopt -u nocasematch
    arg="${BASH_REMATCH[1]}"
    arg="${arg#"${arg%%[![:space:]]*}"}"
    arg="${arg%"${arg##*[![:space:]]}"}"

    hint=""

    if [ -z "$arg" ]; then
        detect_scope
    else
        arg_lower=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')
        case "$arg_lower" in
            all|alle|'*')
                scope_mode="all"; scope_project="" ;;
            global|untagged|ohne)
                scope_mode="global"; scope_project="" ;;
            *)
                # Known projects: distinct [tags] in todos.md + distinct non-empty alias values.
                # Both sources are already global (buffer and aliases.json are shared across
                # all cwds), so the user can reference any project from anywhere.
                known_tags=$(awk '
                    /^\[[0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+\]/ {
                        pe = index($0, "] ")
                        rest = substr($0, pe + 2)
                        if (rest ~ /^\[[^][]+\] /) {
                            pe2 = index(rest, "] ")
                            p = substr(rest, 2, pe2 - 2)
                            if (!(p in seen)) { seen[p] = 1; print p }
                        }
                    }
                ' "$buffer")
                known_aliases=""
                if [ -f "$aliases_file" ]; then
                    known_aliases=$(jq -r 'to_entries | map(select(.value != "")) | .[].value' "$aliases_file" 2>/dev/null)
                fi
                known=$(printf '%s\n%s\n' "$known_tags" "$known_aliases" | awk 'NF && !seen[$0]++')

                exact=""
                substr_list=""
                while IFS= read -r p; do
                    [ -z "$p" ] && continue
                    p_lower=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
                    if [ "$p_lower" = "$arg_lower" ]; then
                        exact="$p"; break
                    fi
                    case "$p_lower" in
                        *"$arg_lower"*) substr_list="${substr_list}${p}"$'\n' ;;
                    esac
                done <<< "$known"

                substr_count=$(printf '%s' "$substr_list" | awk 'NF' | wc -l | tr -d ' ')

                if [ -n "$exact" ]; then
                    scope_mode="project"; scope_project="$exact"
                elif [ "$substr_count" -eq 1 ]; then
                    scope_mode="project"
                    scope_project=$(printf '%s' "$substr_list" | awk 'NF' | head -1)
                    hint="(Übereinstimmung: \"$scope_project\")"$'\n'
                elif [ "$substr_count" -gt 1 ]; then
                    candidates=$(printf '%s' "$substr_list" | awk 'NF' | paste -sd, - | sed 's/,/, /g')
                    msg="Mehrere Projekte passen zu \"$arg\": $candidates. Bitte exakter angeben."
                    emit_block "$msg"
                    exit 0
                else
                    if [ -z "$known" ]; then
                        msg="Kein Projekt \"$arg\" gefunden — es gibt noch keine projekt-getaggten Todos im Buffer."
                    else
                        list=$(printf '%s' "$known" | paste -sd, - | sed 's/,/, /g')
                        msg="Kein Projekt \"$arg\" gefunden. Bekannt sind: $list."
                    fi
                    emit_block "$msg"
                    exit 0
                fi
                ;;
        esac
    fi

    counts=$(awk -v mode="$scope_mode" -v proj="$scope_project" '
        /^\[[0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+\]/ {
            total++
            pe = index($0, "] ")
            rest = substr($0, pe + 2)
            lp = ""
            if (rest ~ /^\[[^][]+\] /) {
                pe2 = index(rest, "] ")
                lp = substr(rest, 2, pe2 - 2)
            }
            keep = 0
            if (mode == "all") keep = 1
            else if (mode == "global" && lp == "") keep = 1
            else if (mode == "project" && lp == proj) keep = 1
            if (keep) shown++
        }
        END { printf "%d %d", shown+0, total+0 }
    ' "$buffer")
    shown=$(printf '%s' "$counts" | awk '{print $1}')
    total=$(printf '%s' "$counts" | awk '{print $2}')
    other=$((total - shown))

    plural() { if [ "$1" -eq 1 ]; then printf '%s' "$2"; else printf '%s' "$3"; fi; }

    if [ "$total" -eq 0 ]; then
        msg="${hint}Der Puffer ist leer."
    elif [ "$shown" -eq 0 ]; then
        other_word=$(plural "$total" "Todo" "Todos")
        case "$scope_mode" in
            project) msg="${hint}Keine Todos im Puffer für \"$scope_project\" (noch $total $other_word im Buffer).";;
            global)  msg="${hint}Keine globalen Todos im Puffer (noch $total projekt-spezifische $other_word im Buffer).";;
            *)       msg="${hint}Der Puffer ist leer.";;
        esac
    else
        shown_word=$(plural "$shown" "Eintrag" "Einträge")
        case "$scope_mode" in
            project) header="**Todo-Puffer — $scope_project** ($shown $shown_word):";;
            global)  header="**Todo-Puffer — global (ohne Projekt-Tag)** ($shown $shown_word):";;
            *)       header="**Todo-Puffer** ($shown $shown_word):";;
        esac
        body=$(awk -v mode="$scope_mode" -v proj="$scope_project" '
            /^\[[0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+\]/ {
                pe = index($0, "] ")
                rest = substr($0, pe + 2)
                lp = ""
                lt = rest
                if (rest ~ /^\[[^][]+\] /) {
                    pe2 = index(rest, "] ")
                    lp = substr(rest, 2, pe2 - 2)
                    lt = substr(rest, pe2 + 2)
                }
                keep = 0
                if (mode == "all") keep = 1
                else if (mode == "global" && lp == "") keep = 1
                else if (mode == "project" && lp == proj) keep = 1
                if (keep) {
                    n++
                    ts = substr($0, 1, index($0, "] "))
                    if (mode == "project")  printf "%d. %s %s\n", n, ts, lt
                    else                    printf "%d. %s\n", n, $0
                }
            }
        ' "$buffer")
        if [ "$other" -gt 0 ]; then
            other_word=$(plural "$other" "weiteres Todo" "weitere Todos")
            case "$scope_mode" in
                project) footer=$(printf '\n\n(noch %d %s im Buffer außerhalb dieses Projekts)' "$other" "$other_word");;
                global)  footer=$(printf '\n\n(noch %d projekt-spezifische%s im Buffer)' "$other" "$( [ "$other" -eq 1 ] && printf 's Todo' || printf ' Todos' )");;
                *)       footer="";;
            esac
        else
            footer=""
        fi
        msg="${hint}${header}
$body$footer"
    fi

    emit_block "$msg"
    exit 0
fi

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
        emit_block "Steht schon drin, nichts geändert."
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

emit_block "$msg"
exit 0
