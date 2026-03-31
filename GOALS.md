# JARVIS — Goals

## What JARVIS Is

An internal command center for running a company with AI agent teams. One person, multiple projects, dozens of agents working in parallel. You open JARVIS and know what every agent is doing, which conversations need you, and where each project stands — the same way a manager uses Slack, but for AI teams.

## Core Principles

**1. The owner's time is the bottleneck.**
Every feature exists to reduce the time between "I need to check on X" and knowing the answer. Status at a glance, not buried in thread history.

**2. Agents are team members, not chatbots.**
They have roles (Architect, Engineer, PM), they have permissions (file access, tools), they work in teams on projects. Treat them like a remote team you're managing async.

**3. Projects organize everything.**
A project is a scope of work with its own #general channel and spawned threads. An agent can be on multiple projects. A thread belongs to one project. This mirrors how real teams work.

**4. #general is the command channel.**
You @mention agents in #general to give directions, ask for updates, or kick off work. Threads spawn when work needs focused attention. #general is where orchestration happens — threads are where execution happens.

**5. History is institutional memory.**
Conversations persist. When a new agent joins a project, it can read past threads to get up to speed. When you revisit a project after weeks, the context is all there.

## User Flows

### Morning check-in
1. Open JARVIS
2. Sidebar shows 3 projects, 2 threads "waiting" (yellow dots)
3. Click first waiting thread → see what the agent produced
4. Respond or approve → agent continues working
5. Click second → same flow
6. Total time: 2 minutes

### Kick off new work
1. Navigate to project's #general
2. Type `@Architect @Engineer I need a plan for migrating the auth system`
3. Both agents respond with their perspectives
4. If deeper work needed: spawn a dedicated thread with those agents
5. Agents work in the thread, status shows "active" then "waiting" when done

### Start a new project
1. Click "New Project" in sidebar
2. Name it, pick a color, select which agents belong
3. #general channel is auto-created with those agents
4. Start directing work immediately

### Add an agent to a running project
1. Open project settings
2. Add the agent
3. Agent can read existing #general history and threads
4. Quickly gets up to speed on context

## Success Metrics (Internal)

- **< 30 seconds** to know the status of all active work
- **< 3 clicks** to find any conversation needing input
- **Zero lost context** — every decision, every conversation, persisted and searchable
- **Agents work unsupervised** between check-ins — tool access, file permissions, collaboration mode let them do real work

## Non-Goals

- Not a public API product
- Not multi-user (single owner)
- Not a model training or fine-tuning platform
- Not a replacement for CI/CD, git, or deployment tools
- Not an agent framework — JARVIS uses Ollama models, it doesn't define agent protocols
