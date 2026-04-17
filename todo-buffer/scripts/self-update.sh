#!/usr/bin/env bash
# Refresh the mcules-plugins marketplace catalog and this plugin so the next
# session picks up new versions automatically. Runs on SessionStart.
#
# Failures are swallowed: offline starts, missing `claude` on PATH, or a
# transient network hiccup must never block the user's session.

set +e

(
  claude plugin marketplace update mcules-plugins
  claude plugin update todo-buffer
) >/dev/null 2>&1

exit 0