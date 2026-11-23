# 11. Keep Holdfast's contract and serve its page; LiveView later

Date: 2026-11-23
Status: Accepted

## Context
The project needs a browser page for the demo, and a stable black-box contract so the later `holdfast-bench` can compare the two systems. Dan chose to reuse Holdfast's React page against the same contract first, with LiveView as a later milestone (decisions log). The Holdfast repo is read-only from here.

## Options considered
1. **Same contract, Holdfast's page served unchanged.** Build Holdfast's `web` package from a pinned Holdfast commit, and serve the static files from this node.
2. **Same contract, our own page.** Full independence of the UI, but it's time spent on something the project doesn't exist to prove.
3. **A LiveView page now.** It would show more of Elixir, but it needs Phoenix (ADR 0010) and drops the shared page.

## Decision
Option 1. The contract in spec §6 is kept exactly, including route prefixes, cookie name, status codes, `minimumNextBid` and SSE event names. Holdfast's page is built from a pinned commit at CI time, without copying its source into this repo, and served by the node.

## Why
A real page for the demo at almost no cost. The contract is proven by a client that wasn't written for this server. It's the same contract `holdfast-bench` will use.

## Consequences
- The page expects contract details beyond the storm's: `/api/config`, `/api/me`, and card setup in real-Stripe mode. Slice 3 re-reads the page's calls and makes the contract tests cover every one.
- A Holdfast change could break the page here. The pinned commit prevents surprises, and a bump is a reviewed PR.
- How the pinned build is fetched (submodule, tag download, or a build step that clones read-only) is decided at slice 3 (decisions log, Q-R2).
