# Jarvis

Jarvis is an LLM API server that runs on a GPU machine. It manages chat history, streams inference, and monitors system resources. Any client — a deployed web app, a mobile app, a CLI — talks to the same API.

The Phoenix LiveView frontend (`/chat`) is a reference client built on top of the API, not a separate product. Every feature in the UI goes through the same service layer that external clients use.

```
                              [GPU Machine]
                          ┌─────────────────────────┐
Railway app  ──HTTPS──┐   │  Jarvis (Phoenix)        │
Mobile app   ──HTTPS──┼──ngrok──> API ──> Chat Context ──> Ollama
CLI tool     ──HTTPS──┤   │        │    └─> GPU Monitor  │
Browser      ──HTTPS──┘   │        │                     │
  (LiveView = API client)  │        └──> PostgreSQL       │
                          └─────────────────────────┘
```

## Architecture

```
┌─ Clients (any)
│
├─ API Layer (controllers)        ← JSON / SSE
├─ LiveView UI (live views)       ← WebSocket, same service calls
│
├─ Service Layer (contexts)       ← Jarvis.Chat, Jarvis.Inference, Jarvis.Resources
│   ├─ Chat context              ← CRUD conversations & messages (Postgres)
│   ├─ Inference context          ← model selection, streaming, provider abstraction
│   └─ Resources context          ← GPU stats, queue depth, availability gating
│
├─ Providers                      ← Jarvis.Providers.Ollama (future: vLLM, llama.cpp)
└─ Database                       ← Ecto / PostgreSQL
```

The key constraint: **LiveView never calls Ollama directly**. It goes through `Jarvis.Inference` and `Jarvis.Chat`, same as the REST API. This keeps one path for chat logic, persistence, and resource checks regardless of the client.

## Local Development

```bash
mix setup          # install deps, create db, build assets
mix phx.server     # start on localhost:4000
```

The web UI is at `http://localhost:4000/chat` — useful for testing, but the API is the primary interface.

---

## Roadmap

### Phase 1 — Service Layer & Persistence

Build the core contexts that both the API and LiveView will use. The LiveView currently calls `Jarvis.Ollama` directly — this phase introduces the service layer and persistence.

- [ ] `Jarvis.Chat` context — create/list/get/delete conversations, append messages
- [ ] `Jarvis.Inference` context — wraps Ollama (and future providers), handles streaming, persists the assistant response on completion
- [ ] `Jarvis.Resources` context — polls GPU stats, tracks queue depth, exposes availability status
- [ ] `chats` table — `id`, `title`, `model`, `inserted_at`, `updated_at`
- [ ] `messages` table — `id`, `chat_id`, `role` (user/assistant/system), `content`, `inserted_at`
- [ ] Auto-generate chat titles from the first user message
- [ ] Refactor `ChatLive` to call `Jarvis.Chat` and `Jarvis.Inference` instead of `Jarvis.Ollama` directly

### Phase 2 — REST API

Expose the service layer as an HTTP API. All endpoints are JSON, streaming endpoints use Server-Sent Events (SSE). These are the same functions the LiveView already calls — just a different transport.

#### Authentication

All API requests require a bearer token:

```
Authorization: Bearer <JARVIS_API_KEY>
```

#### Endpoints

**Models**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/models` | List available Ollama models |
| `GET` | `/api/resources` | GPU utilization, VRAM usage, queue depth |

**Chats**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/chats` | List all conversations (paginated) |
| `POST` | `/api/chats` | Create a new conversation |
| `GET` | `/api/chats/:id` | Get a conversation with its messages |
| `DELETE` | `/api/chats/:id` | Delete a conversation |

**Messages**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/chats/:id/messages` | Send a message and get a response |
| `POST` | `/api/chats/:id/messages/stream` | Send a message, receive response as SSE |

#### Streaming (SSE)

`POST /api/chats/:id/messages/stream` returns a stream of server-sent events:

```
POST /api/chats/1/messages/stream
Content-Type: application/json
Authorization: Bearer <token>

{"content": "Explain quicksort"}
```

```
event: chunk
data: {"content": "Quick"}

event: chunk
data: {"content": "sort is"}

event: chunk
data: {"content": " a divide..."}

event: done
data: {"message_id": 42}
```

The full assistant response is persisted to the database automatically. The client never has to send a second request to save it.

#### Resource Awareness

`GET /api/resources` returns current machine stats:

```json
{
  "gpu": {
    "utilization_percent": 45,
    "vram_used_mb": 6200,
    "vram_total_mb": 24576
  },
  "queue": {
    "pending_requests": 2
  },
  "status": "available"
}
```

Status values: `available`, `busy`, `overloaded`. When `overloaded`, the API returns `503 Service Unavailable` on new chat requests so clients can back off or show a queue indicator.

### Phase 3 — ngrok Tunnel

Expose Jarvis to the internet so deployed apps can reach it.

#### Setup

1. Install ngrok:

```bash
# snap
sudo snap install ngrok

# or direct download
curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok-v3-stable-linux-amd64.tgz | sudo tar xzf - -C /usr/local/bin
```

2. Authenticate (one-time):

```bash
ngrok config add-authtoken <YOUR_TOKEN>
```

3. Set up a persistent tunnel with a fixed domain (paid feature):

```bash
ngrok http 4000 --domain=jarvis.ngrok.dev
```

With a paid plan you get a stable domain — your Railway app always calls `https://jarvis.ngrok.dev/api/...` and it never changes.

#### Running as a systemd Service

So the tunnel survives reboots:

```ini
# /etc/systemd/system/ngrok-jarvis.service
[Unit]
Description=ngrok tunnel for Jarvis
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ngrok http 4000 --domain=jarvis.ngrok.dev
Restart=always
RestartSec=5
User=jarvis

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now ngrok-jarvis
```

#### ngrok Configuration File

For more complex setups, use `~/.config/ngrok/ngrok.yml`:

```yaml
version: "3"
agent:
  authtoken: <YOUR_TOKEN>

tunnels:
  jarvis:
    proto: http
    addr: 4000
    domain: jarvis.ngrok.dev
    inspect: false
```

Then run:

```bash
ngrok start jarvis
```

#### Security Considerations

- **Always use bearer token auth** on the API — ngrok makes the port public
- **Rate limiting** — add a Plug to throttle requests per token
- ngrok's dashboard (`http://localhost:4040`) shows request logs, useful for debugging
- Consider IP allowlisting in ngrok's config if your Railway app has a known egress IP

### Phase 4 — Multi-Model & Provider Support

Extend beyond Ollama to support multiple backends.

- [ ] Provider abstraction — common interface for Ollama, llama.cpp, vLLM, etc.
- [ ] Per-model resource tracking — know which models are loaded and their VRAM footprint
- [ ] Model auto-loading — pull and load models on demand via the API
- [ ] Routing — send requests to the right backend based on model name

### Phase 5 — Web UI (Reference Client)

The LiveView frontend is a proof-of-concept client. It demonstrates what the API can do and is useful for direct local use, but it's not the primary product.

- [ ] Conversation list with search
- [ ] Markdown rendering with syntax highlighting
- [ ] Resource dashboard — live GPU stats in the browser
- [ ] Multi-model comparison — send the same prompt to multiple models side by side
