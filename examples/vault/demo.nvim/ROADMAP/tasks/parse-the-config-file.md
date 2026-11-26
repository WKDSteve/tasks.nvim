---
title: Parse the config file
status: open
kind: feature
prio: 1
effort: S
value: 4
actor: cdx
plan: demo.nvim/first-release
phase: core
created: 2026-01-05
updated: 2026-01-05
---

Read the user's config and report unknown keys.

## Context

Users mistype keys and nothing tells them; the plugin should say so on startup.

## Acceptance

- [ ] a known key is read
- [ ] an unknown key is named in one warning

## Notes

Part of the first release, stage core.
