# JARVIS Roadmap — Project-Based Agent Workspace

## Vision

JARVIS is a command center for running a company with autonomous AI agent teams. One owner, multiple projects, dozens of agents working in parallel -- managed through a Slack-style LiveView interface.

**Today:** Running on a NUC with 8B models. Useful for directed conversations and lightweight agent work. The UI, data model, and orchestration layer are the product.

**Endgame:** Serious GPU hardware (5090s, multi-GPU), 70B+ code-agent-class models with 128K-1M context windows. Agents that genuinely reason, plan, and execute autonomously. JARVIS becomes the management layer for a real AI workforce -- not a chat wrapper, but the interface between the owner and agents that can do unsupervised work across days and projects.

**Architecture principle:** Design for the endgame, ship for today. Context systems, orchestration, and tool access should work with 8B/8K right now and get dramatically more powerful as models and hardware scale up. Never design around current limits as if they are permanent.

## Architecture

Projects > Channels + Threads > Messages with @mention-routed agents.

```
┌─ Sidebar (Slack-style)                  ┌─ Main Content
│                                          │
│  ▼ Project Alpha        ●               │  # general
│    # general             ●               │  [thread header + status]
│    ↳ auth-refactor       ○ waiting       │  [messages]
│    ↳ api-redesign        ● active        │  [input with @mention]
│                                          │
│  ▼ Project Beta          ⚠               │
│    # general             ○ waiting       │
│    ↳ db-migration        ● idle          │
│                                          │
│  Inbox                                   │
│    orphan-thread         ○               │
```

## Completed (v1)

### Data Model
- [x] `projects` table with name, description, color, archived_at, metadata
- [x] `threads` updated: project_id (FK), type (general/thread), status (active/waiting/idle/error/archived)
- [x] `thread_personas` updated: allowed_tools array for per-persona tool filtering
- [x] Unique partial index: one #general channel per project
- [x] Project schema with has_many threads

### Contexts
- [x] `Jarvis.Projects` — CRUD, auto-creates #general on project creation, agent management per project
- [x] `Jarvis.Chat` — rewritten with project-aware queries, @mention parsing, status management, waiting thread detection
- [x] `Jarvis.Agents` — extracted persona CRUD (renamed from contacts to agents)

### ThreadServer Enhancements
- [x] Status persistence to DB (active/waiting/idle/error) on all state transitions
- [x] Persona filtering via `send_message/3` opts — enables @mention routing in general channels
- [x] Tool filtering — `allowed_tools` per persona per thread
- [x] Auto "waiting" status when agent finishes responding

### Ollama
- [x] Configurable base URL (env var `OLLAMA_URL`, config `Jarvis.Ollama, base_url:`)

### UI — Workspace
- [x] `WorkspaceLive` — single LiveView for the entire workspace
- [x] Slack-style sidebar: compact rows (status dot + name), collapsible projects, #general always first
- [x] Filter tabs: All | Waiting (with count badge) | Active
- [x] Project creation modal with agent picker
- [x] Thread spawning modal from general channel
- [x] @mention detection in general channels with autocomplete dropdown
- [x] Thread header with participant avatars, status text, spawn/settings/delete controls
- [x] Message list with persona colors, markdown rendering, streaming indicators
- [x] Settings panel: collaboration toggle, per-agent paths, model/thinking config
- [x] `AgentLive` — full agent CRUD (replaces PersonaLive)
- [x] Status dots: green+pulse (active), yellow (waiting), red (error), gray (idle)
- [x] Aggregate project status (worst of children)

### Infrastructure
- [x] 3 database migrations
- [x] Seeds create default "JARVIS" project with all agents
- [x] All tests passing
- [x] Old POC LiveViews deleted (ThreadLive, PersonaLive, ChatLive)

---

## Completed (v1.1) — Hardening & Core UX

### Reliability
- [x] ThreadServer `terminate/2` crash recovery — thread resets to "error" on unexpected death, no more permanently stuck "active" threads
- [x] Single status broadcast path — removed dual broadcast from `Chat.update_thread_status` and `ThreadServer`; one source of truth

### UX
- [x] @mention autocomplete: keyboard nav (up/down/enter), insert into input
- [x] Thread search in sidebar (by name, content)
- [x] Archive threads from sidebar
- [x] Copy message button
- [x] Markdown syntax highlighting in code blocks

---

## Next Up

Priority order. Each section is a shippable increment.

### 1. Agent Context — Project Briefs & Decision Log
The single highest-impact gap. Today, every agent starts from scratch. This makes agents feel like team members instead of strangers. Works with 8B models now (concise brief in system prompt), becomes dramatically more powerful with 70B+ models and large context windows (full project history, cross-thread awareness).

- [ ] **Project brief** — owner-written markdown document per project, injected into every agent's system prompt for that project. Contains goals, tech stack, constraints, conventions. Editable from project settings.
- [ ] **Decision log** — append-only, timestamped list at the project level. Owner adds entries when key decisions are made in any thread. Injected into system prompt alongside the brief. Agents see what was decided without needing the discussion that led there.
- [ ] **Thread spawn with context** — when spawning a thread from #general, include a summary of the relevant #general conversation as the first message. Agents in the new thread know why they are there.
- [ ] **Context assembly pipeline** — `Chat.messages_for_ollama/3` becomes context-window-aware: project brief + decision log + thread history, assembled with a configurable token budget. Small models get brief + decisions + recent messages. Large models get everything.

### 2. WorkspaceLive Refactor
The 960-line monolith is the main maintenance risk. Extract before it gets worse.
- [ ] Extract sidebar event handlers into `WorkspaceLive.Sidebar` component module
- [ ] Extract message/thread event handlers into `WorkspaceLive.Thread` component module
- [ ] Extract settings panel into `WorkspaceLive.Settings` component module
- [ ] Targeted PubSub updates instead of full sidebar reload on every event (fix N+1)

### 3. Keyboard-Driven Navigation
The owner's hands are on the keyboard all day. Reduce mouse dependency.
- [ ] Cmd+K quick switch (projects, threads, agents)
- [ ] Cmd+N new thread from anywhere
- [ ] Escape to close modals/panels

### 4. Project Management
Basic project lifecycle. Needed once there are more than 2-3 projects.
- [ ] Project edit/rename from sidebar context menu
- [ ] Project archive (hide from sidebar, accessible via filter)
- [ ] Conversation export (Markdown)

### 5. Permissions UX
The data model supports per-agent tool filtering. Surface it better.
- [ ] Permission presets: "read-only", "full-access", "code-only"
- [ ] Visual indicators in thread header for active permissions
- [ ] Default permissions per agent (applied on add to new threads)

---

## Future

Parked until daily usage or hardware upgrades reveal real need. Not scheduled. Items marked [endgame] become high-priority once running 70B+ models.

- Thread summaries — agent-generated compressed history for long threads. Valuable at any model size for efficiency; essential at 8B, optional at 128K+ context. [endgame: auto-summarize on idle]
- Cross-thread context injection — feed an agent summaries or full history from other threads in the same project. Requires large context windows to be useful beyond summaries. [endgame]
- Agent onboarding — "catch up" button that summarizes a project for a newly added agent using the brief + decision log + thread summaries. [endgame]
- Agent handoff — one agent delegates to another mid-thread with context transfer. [endgame]
- Scheduled agent runs — agents execute on a schedule (daily standups, periodic reviews). [endgame]
- Agent templates (preset persona + permissions + system prompt)
- Thread templates (preset multi-agent configs)
- Message editing and regeneration
- Thread notes/annotations (owner's notes, not sent to agent)
- Drag threads between projects
- Mobile-responsive sidebar
- Structured logging (JSON) for production
- Telemetry events for inference latency, token counts
- Health check endpoint
- GPU resource monitoring
- Machine resources page — htop-style dashboard tab in the workspace showing GPU/CPU/RAM utilization, model loading status, and inference queue depth. Useful at any hardware scale for knowing why an agent is slow or stuck.
- Root SSH REPL — embedded terminal on the resources page for direct machine access. Manage Ollama, tail logs, kill stuck processes without leaving JARVIS. [endgame: power-user feature for multi-GPU management]
