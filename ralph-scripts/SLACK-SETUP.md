# Slack Integration Setup Guide

This guide walks you through setting up bidirectional Slack communication with Ralph.

## Quick Start (Webhook Mode - Outbound Only)

If you just want notifications (no responses), this is the simplest setup:

### 1. Create Incoming Webhook

1. Go to https://api.slack.com/apps
2. Click "Create New App" → "From scratch"
3. Name it "Ralph" and select your workspace
4. Go to "Incoming Webhooks" → Enable it
5. Click "Add New Webhook to Workspace"
6. Select the channel (e.g., #ralph-updates)
7. Copy the webhook URL

### 2. Configure Ralph

```bash
export SLACK_WEBHOOK_URL="<your-webhook-url-from-slack>"
```

Or add to your shell profile (~/.zshrc or ~/.bashrc):
```bash
echo 'export SLACK_WEBHOOK_URL="your-webhook-url"' >> ~/.zshrc
```

### 3. Test It

```bash
./ralph-scripts/ralph-notify.sh text "Hello from Ralph!"
```

---

## Full Setup (Bot Mode - Bidirectional)

For full functionality (receiving responses, button clicks), you need a Slack Bot.

### 1. Create Slack App

1. Go to https://api.slack.com/apps
2. Click "Create New App" → "From scratch"
3. Name: "Ralph Assistant"
4. Select your workspace

### 2. Configure Bot Token Scopes

Go to "OAuth & Permissions" and add these Bot Token Scopes:

| Scope | Purpose |
|-------|---------|
| `chat:write` | Send messages |
| `channels:history` | Read channel messages |
| `channels:read` | List channels |
| `users:read` | Get user info |
| `reactions:write` | Add reactions |

### 3. Enable Events (Optional - for real-time responses)

Go to "Event Subscriptions":

1. Enable Events
2. Set Request URL (requires public URL - see ngrok section below)
3. Subscribe to bot events:
   - `message.channels`
   - `app_mention`

### 4. Enable Interactivity (for button clicks)

Go to "Interactivity & Shortcuts":

1. Enable Interactivity
2. Set Request URL (same as events, or different endpoint)

### 5. Install App to Workspace

1. Go to "Install App"
2. Click "Install to Workspace"
3. Authorize the permissions
4. Copy the "Bot User OAuth Token" (starts with `xoxb-`)

### 6. Configure Ralph

```bash
export SLACK_BOT_TOKEN="xoxb-your-token-here"
export SLACK_CHANNEL="#ralph-updates"
```

### 7. Test Connection

```bash
./ralph-scripts/ralph-slack.sh test
# Should show: "Connected as @ralph in YourWorkspace workspace (bot mode)"
```

---

## Listening for Responses

### Option A: Polling Mode (Simple, No Public URL)

Ralph periodically checks Slack for new messages:

```bash
# Start listener in background
./ralph-scripts/ralph-slack-listener.sh start poll

# Or run in foreground
./ralph-scripts/ralph-slack-listener.sh poll
```

Pros:
- Works anywhere (no public URL needed)
- Simple setup

Cons:
- Slight delay (10 second poll interval by default)
- More API calls

### Option B: HTTP Mode (Real-time, Requires Public URL)

For instant responses, Ralph runs an HTTP server that Slack sends events to:

```bash
# Start HTTP listener
./ralph-scripts/ralph-slack-listener.sh start http
```

Requires a public URL. Options:

#### Using ngrok (Development)

```bash
# Install ngrok
brew install ngrok

# Start tunnel
ngrok http 3000

# Copy the https URL (e.g., https://abc123.ngrok.io)
```

Then configure in Slack App:
- Event Subscriptions URL: `https://abc123.ngrok.io/slack/events`
- Interactivity URL: `https://abc123.ngrok.io/slack/interactions`

#### Using a VPS/Server (Production)

Deploy the listener to a server with a domain, or use a service like:
- Railway
- Render
- Fly.io
- Your own VPS with nginx

---

## Environment Variables Reference

| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_WEBHOOK_URL` | For webhook mode | Incoming webhook URL |
| `SLACK_BOT_TOKEN` | For bot mode | Bot User OAuth Token (xoxb-...) |
| `SLACK_CHANNEL` | No | Channel for messages (default: #ralph-updates) |
| `SLACK_POLL_INTERVAL` | No | Seconds between polls (default: 10) |
| `SLACK_HTTP_PORT` | No | Port for HTTP listener (default: 3000) |

---

## Integration with Ralph Orchestrator

To start Ralph with Slack integration:

```bash
# Set environment variables
export SLACK_BOT_TOKEN="xoxb-your-token"
export SLACK_CHANNEL="#ralph-updates"

# Start Ralph (listener starts automatically)
./ralph-scripts/ralph-orchestrator.sh run
```

The orchestrator will:
1. Start the Slack listener daemon
2. Send startup notification
3. Forward all agent events to Slack
4. Receive and process your responses

---

## Slack Commands

Once connected, you can interact with Ralph via Slack:

| Command | Description |
|---------|-------------|
| `status` | Show current progress |
| `pause` | Pause all agents |
| `resume` | Resume agents |
| `abort` | Stop Ralph |
| `decisions` | Show pending decisions |
| `help` | Show available commands |
| `1`, `2`, `3` | Quick answer to most recent decision |
| `dec-123456 Answer` | Answer specific decision |

### Example Interactions

```
You: status
Ralph: 📊 Progress: ████████░░ 80% (8/10 features)
       ✅ Completed: 6
       🔄 In Progress: 2
       ...

You: decisions
Ralph: ❓ Pending Decisions (1):
       1. Which authentication method?
          Options: JWT, Sessions, OAuth
          ID: dec-1704567890

You: dec-1704567890 JWT
Ralph: ✅ Got it! Using JWT
```

---

## Notification Types

Ralph sends these notification types:

| Event | What You See |
|-------|--------------|
| Start | "🚀 Ralph Started - 3 agents, flat mode" |
| Feature Started | "🚀 agent-1 started: User Login (auth-001)" |
| Feature Completed | Rich card with PR link, files changed, approve button |
| Blocked | "🚫 Blocked: auth-001 - reason" with unblock instructions |
| Decision Needed | Interactive buttons to choose options |
| Error | "❌ Error: description" |
| Progress | Progress bar, stats, cost |
| Complete | "🎉 All features complete!" |

---

## Troubleshooting

### "Slack not configured"

```bash
# Check your environment variables
echo $SLACK_WEBHOOK_URL
echo $SLACK_BOT_TOKEN

# Test connection
./ralph-scripts/ralph-slack.sh test
```

### Messages not appearing

1. Check the channel exists and bot is invited:
   ```
   /invite @Ralph
   ```

2. Verify bot has `chat:write` permission

3. Check logs:
   ```bash
   tail -f progress/slack.log
   ```

### Not receiving responses

1. Ensure listener is running:
   ```bash
   ./ralph-scripts/ralph-slack-listener.sh status
   ```

2. Check bot has `channels:history` permission

3. For HTTP mode, verify Slack can reach your URL:
   - Check ngrok dashboard for incoming requests
   - Verify URL in Slack App settings

### Button clicks not working

1. Ensure Interactivity is enabled in Slack App
2. Verify Request URL is correct
3. Check for errors in Slack App dashboard

---

## Security Notes

1. **Keep tokens secret**: Never commit `SLACK_BOT_TOKEN` to git
2. **Use environment variables**: Store secrets in env vars or secret manager
3. **Limit channel access**: Use private channels for sensitive projects
4. **Review permissions**: Only grant necessary OAuth scopes

---

## Example: Full Setup Script

```bash
#!/bin/bash
# setup-slack.sh - One-time Slack setup for Ralph

# Check for required variables
if [[ -z "$SLACK_BOT_TOKEN" ]]; then
  echo "Error: SLACK_BOT_TOKEN not set"
  echo "Get it from: https://api.slack.com/apps → Your App → OAuth & Permissions"
  exit 1
fi

# Test connection
echo "Testing Slack connection..."
./ralph-scripts/ralph-slack.sh test || exit 1

# Create channel if needed (manual step)
echo ""
echo "Make sure to:"
echo "1. Create #ralph-updates channel (if it doesn't exist)"
echo "2. Invite the bot: /invite @Ralph"
echo ""

# Send test message
echo "Sending test message..."
./ralph-scripts/ralph-notify.sh text "👋 Ralph is connected and ready!"

echo ""
echo "Setup complete! Start Ralph with:"
echo "  ./ralph-scripts/ralph-orchestrator.sh run"
```

---

## Next Steps

1. Set up Slack App and get tokens
2. Configure environment variables
3. Test with `./ralph-slack.sh test`
4. Start Ralph and watch notifications flow!

For questions or issues, check the logs at `progress/slack.log`.
