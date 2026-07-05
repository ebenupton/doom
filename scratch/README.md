# Scratch — one-off diagnostic/probe scripts

Point-in-time investigation scripts, quarantined from the repo root.
They import repo-root modules, so run them with the root on PYTHONPATH:

    PYTHONPATH=. python3 scratch/<script>.py

Many reference address layouts or module APIs from the era they were
written and may need updating against symmap/ENGINE.md before use.
