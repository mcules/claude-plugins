#!/usr/bin/env bash
# Refresh all installed marketplace catalogs and this plugin so the next
# session picks up new versions automatically. Runs on SessionStart.
#
# The `marketplace update` call is intentionally unscoped: this plugin may be
# installed via different marketplaces (the main one, a personal fork, a
# re-exporting catalog, ...). Refreshing whichever the user has registered
# keeps the hook portable.
#
# Failures are swallowed: offline starts, missing `claude` on PATH, or a
# transient network hiccup must never block the user's session.

set +e

(
  claude plugin marketplace update
  claude plugin update todo-buffer
) >/dev/null 2>&1

exit 0