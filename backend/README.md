# Backend - Video Generation API

Phoenix API backend for video generation using Replicate and XAI APIs.

## Setup

### Prerequisites
- Elixir 1.15 or later
- Erlang/OTP 24 or later

### Environment Variables
Copy `.env.example` to `.env` and configure:
```bash
cp .env.example .env
```

Required environment variables:
- `REPLICATE_API_KEY` - Your Replicate API key (get from https://replicate.com/account/api-tokens)
- `XAI_API_KEY` - Your XAI API key (get from https://x.ai/api)
- `PUBLIC_BASE_URL` - Publicly reachable base URL (ngrok in development, Fly URL in prod) so Replicate can fetch first/last-frame assets.
- `VIDEO_GENERATION_MODEL` - Default Replicate model (`veo3` or `hilua-2.5`) used for rendering; can be overridden per request.
- `REPLICATE_WEBHOOK_URL` *(optional)* - If you need Replicate to POST status callbacks, point this at a real HTTPS endpoint; leave blank to disable webhooks (recommended until a handler exists).

### Installation

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Database

This project uses SQLite3 with WAL (Write-Ahead Logging) mode for better concurrency:
- Development DB: `backend_dev.db` in the project root
- Test DB: `backend_test.db`
- Production DB: Configured via `DATABASE_PATH` environment variable

## Dependencies

Key dependencies:
- Phoenix 1.8.1 - Web framework
- Ecto + ecto_sqlite3 - Database layer with SQLite adapter
- Req 0.4 - HTTP client for API calls
- Jason 1.4 - JSON encoding/decoding
- Bandit - HTTP server

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
