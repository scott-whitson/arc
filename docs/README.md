# arc — documentation

ARC is a local, offline, config-aware retrieval engine for Emacs. It indexes
this machine's configuration and notes, returns ranked source records, and
keeps citations navigable. It is a hard fork of ELISA by Sergey Kostyaev.

The package README is the current behavior guide. This directory contains
historical design records plus the live MCP integration note below.

## Live documentation

- [`mcp.md`](mcp.md) — local stdio MCP configuration, the five read-only tools,
source preview workflow, and the retrieved-data trust boundary.

## Historical design records

The dated files under `design/` and `superpowers/` record decisions and plans
at the time they were written. They are intentionally not rewritten to match
today's implementation: some describe the former prose-answer surface or
rejected alternatives. Use `README.org` and `mcp.md` for current behavior.
