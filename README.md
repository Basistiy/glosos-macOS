# glosos-macOS
Glosos voice agent for Mac OS

## Run the local Glosos container

The app can now manage the local backend for you with Apple's `container` CLI.

Requirements:

- Apple silicon Mac
- macOS 26 or newer
- Apple's `container` CLI installed from:
  [github.com/apple/container/releases](https://github.com/apple/container/releases)

After installing the CLI once, start its system service:

```bash
container system start
```

The app now lets you:

- pull and run `ghcr.io/basistiy/glosos-google-user:latest`
- publish the backend on `127.0.0.1:18000`
- connect automatically to `ws://127.0.0.1:18000/ws`
- switch back to a manual websocket URL if needed
- connect and disconnect from the local websocket agent
- send a typed prompt or the current live transcript
- view streamed agent output and websocket events
- speak the agent's final reply with Apple TTS

If the CLI is missing, the app shows setup guidance in Settings.
