---
name: No External API
description: JARVIS is an internal tool, not an API product — do not plan REST API, auth tokens, or multi-client architecture
type: feedback
---

JARVIS is an internal tool for a single company owner, not an API product for external clients.

**Why:** Matt uses this to manage project conversations with AI agents. The LiveView UI IS the product. No need for REST API, bearer tokens, rate limiting, or multi-client support.

**How to apply:** Focus improvements on the LiveView experience, agent management UX, and internal workflows. Skip API controllers, auth middleware, OpenAPI docs, CORS, etc.
