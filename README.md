# glosos-macOS
Glosos voice agent for Mac OS

## Connect to the local Glosos container

This app can connect to the standalone websocket runtime in:

`/Users/evgeniibasistyi/Documents/GitHub/glosos-google-user`

Start that service first:

```bash
cd /Users/evgeniibasistyi/Documents/GitHub/glosos-google-user
docker compose up --build
```

On this machine, the standalone local-agent container is currently available on:

`ws://127.0.0.1:18000/ws`

`localhost:8000` is already occupied by the main `glosos-google-gateway`, so use the websocket URL above unless you remap ports in the container repo.

The app now lets you:

- connect and disconnect from the local websocket agent
- send a typed prompt or the current live transcript
- view streamed agent output and websocket events
- speak the agent's final reply with Apple TTS
