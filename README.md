# claude-queue

AI-powered issue implementation queue for GitHub repos, controlled via Telegram. Send a message, get a PR.

Built on [Claude Code](https://github.com/anthropics/claude-code) + GitHub Actions.

## How it works

1. You send `queue 42 43 44` to your Telegram bot
2. The bot adds those issue numbers to `QUEUE.md` in your repo
3. A GitHub Actions workflow picks them up one by one, runs Claude Code to implement each, creates a PR, and notifies you
4. You review and reply `merge 42` — bot merges and moves to the next issue

## Setup

### 1. Create a Telegram bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts (choose a name and username)
3. BotFather will give you a **bot token** — save it
4. Message your new bot once (so it has a chat with you)
5. Visit this URL to get your **chat ID**:
   ```
   https://api.telegram.org/bot<BOT_TOKEN>/getUpdates
   ```
   Look for `"chat": {"id": <YOUR_CHAT_ID>}` in the response

### 2. Add secrets to your repo

Go to **Settings → Secrets → Actions** and add:

| Secret | Description |
|--------|-------------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key |
| `TELEGRAM_BOT_TOKEN` | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_CHAT_ID` | Your chat ID (see below) |
| `GH_PAT` | GitHub Personal Access Token with `repo` + `actions:write` scopes |
| `FLY_API_TOKEN` | *(Optional)* Fly.io API token, only needed if using deploy hooks |


### 3. Add workflow files to your repo

Create these three files in `.github/workflows/`:

**`.github/workflows/telegram-receiver.yml`**
```yaml
name: Telegram Receiver

on:
  schedule:
    - cron: '* * * * *'
  workflow_dispatch:

concurrency:
  group: telegram-receiver
  cancel-in-progress: false

jobs:
  receive:
    uses: WordenPond/claude-queue/.github/workflows/telegram-receiver.yml@main
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
      GH_PAT: ${{ secrets.GH_PAT }}
      # FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}  # uncomment if using deploy hooks
```

**`.github/workflows/queue-processor.yml`**
```yaml
name: Queue Runner

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths:
      - "QUEUE.md"

jobs:
  run-queue:
    uses: WordenPond/claude-queue/.github/workflows/queue-processor.yml@main
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
      GH_PAT: ${{ secrets.GH_PAT }}
```

**`.github/workflows/implement-issue.yml`**
```yaml
name: Implement Issue

on:
  workflow_dispatch:
    inputs:
      issue_number:
        description: 'GitHub issue number to implement'
        required: true

jobs:
  implement:
    uses: WordenPond/claude-queue/.github/workflows/implement-issue.yml@main
    with:
      issue_number: ${{ github.event.inputs.issue_number }}
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
      GH_PAT: ${{ secrets.GH_PAT }}
```

### 4. Add QUEUE.md

Create a `QUEUE.md` at your repo root:

```markdown
# Agent Issue Queue

## Queue

<!-- Add issues below — one per line, highest priority first -->
```

### 5. Customize the implement prompt (optional)

By default, claude-queue uses [`prompts/implement-default.txt`](prompts/implement-default.txt) — a generic prompt that works for most projects.

To customize for your project, create `.github/prompts/implement.txt` in your repo. Reference your own docs, conventions, and rules. claude-queue will automatically use your file if it exists.

### 6. Add project hooks (optional)

To enable the `deploy`, `staging`, and `health` Telegram commands, create `scripts/claude-queue-hooks.sh` in your repo and define one or more of these shell functions:

```bash
deploy_production() {
  # your production deploy logic here
  fly deploy --app my-app
}

deploy_staging() {
  # your staging deploy logic here
  fly deploy --app my-app-staging
}

health_check() {
  # return health status as a string
  curl -sf https://my-app.fly.dev/healthz && echo "healthy" || echo "unhealthy"
}

staging_health_check() {
  curl -sf https://my-app-staging.fly.dev/healthz && echo "healthy" || echo "unhealthy"
}
```

The hooks file is sourced at the start of every Telegram receiver run. Only define the functions you need — undefined commands will respond with a helpful error.

## Telegram commands

| Command | Description |
|---------|-------------|
| `queue 42 43 44` | Add issues to the queue |
| `queue` | Trigger the queue runner immediately |
| `merge 42` | Merge PR #42 and advance the queue |
| `rev 42` | Re-review and fix PR #42 |
| `implement 42` | Implement a single issue outside the queue |
| `status` | Show queue status (pending/done/next) |
| `pause` | Pause the queue |
| `resume` | Resume the queue |
| `deploy` | Deploy to production (requires hook) |
| `staging` | Deploy to staging (requires hook) |
| `health` | Check production health (requires hook) |
| `staging-health` | Check staging health (requires hook) |
| `help` | Show command list |

## Architecture

```
Your repo
├── .github/workflows/
│   ├── queue-processor.yml     (thin wrapper → calls claude-queue)
│   ├── implement-issue.yml     (thin wrapper → calls claude-queue)
│   └── telegram-receiver.yml   (thin wrapper → calls claude-queue)
├── .github/prompts/
│   └── implement.txt           (optional: your custom prompt)
├── scripts/
│   └── claude-queue-hooks.sh   (optional: deploy/health hooks)
├── QUEUE.md                    (the issue queue)
└── .telegram-last-id           (persists Telegram poll offset)

WordenPond/claude-queue         (this repo — shared logic)
├── .github/workflows/
│   ├── queue-processor.yml     (reusable workflow)
│   ├── implement-issue.yml     (reusable workflow)
│   └── telegram-receiver.yml   (reusable workflow)
├── scripts/
│   ├── notify-telegram.sh
│   └── parse_telegram.py
└── prompts/
    └── implement-default.txt
```

## Requirements

- GitHub Actions enabled on your repo
- `GITHUB_TOKEN` permissions: `contents: write`, `pull-requests: write`, `issues: write`
- The `GH_PAT` token needs `actions:write` to trigger `workflow_dispatch` (the default `GITHUB_TOKEN` cannot trigger other workflows)

## License

MIT
