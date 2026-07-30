# glosos-macOS

![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon-lightgrey)

Native macOS client and runtime manager for **Glosos** — an interactive real-time voice agent and AI assistant platform.

---

## 🌟 Overview

**glosos-macOS** brings low-latency, real-time AI voice conversations directly to your Mac. Built with native SwiftUI and Swift 6, it features direct local container runtime management using Apple's native `Containerization` framework, on-device Silero VAD (Voice Activity Detection), WebRTC real-time transport, and multi-provider model support.

---

## ✨ Features

- **Direct Apple Containerization Integration**: Runs backend containers directly on macOS 26+ using Apple's `Containerization` Swift APIs without relying on Docker or external CLI tools. Automatically provisions the Linux kernel, init environment (`vminit`), vmnet networking, and container lifecycle.
- **Real-Time Voice Assistant**: Low-latency voice interaction with live speech-to-text transcription, local Silero VAD turn coordination, and natural Apple Text-to-Speech (TTS) synthesis.
- **Multiple Model Providers**:
  - **Google Gemini**: Native integration with Gemini models (`GOOGLE_API_KEY`).
  - **Cerebras Inference**: High-speed inference using Cerebras (`CEREBRAS_API_KEY`).
  - **Custom LLM**: Connect to local or remote OpenAI-compatible endpoints (Ollama, LM Studio, vLLM).
- **Flexible Runtime Modes**:
  - **Managed Container**: Automated container pulling, starting, health checking, and lifecycle management for `ghcr.io/basistiy/glosos-google-user:latest`.
  - **Manual Endpoint**: Connect directly to an external backend service or remote container host.
- **WebRTC & Streaming Transport**: Supports HTTP streaming (Server-Sent Events) and WebRTC P2P signaling for high-throughput streaming events.
- **Modern UI & Onboarding**: Clean macOS interface with setup onboarding, interactive audio visualization, live event logging, and configurable settings.
- **System Power Management**: Smart power assertions prevent system sleep during active voice calls.

---

## 📋 Requirements

- **Operating System**: macOS 26.0 or newer
- **Hardware**: Apple silicon Mac (M1/M2/M3/M4 or newer) recommended for native virtualization
- **Tools**: Xcode 16+ with Swift 6
- **Entitlements** (for development/building):
  - Virtualization (`com.apple.security.virtualization`)
  - Microphone access and speech recognition permissions

---

## 🚀 Getting Started

### 1. Build and Run

1. Open `glosos-macOS.xcodeproj` in **Xcode 16+**.
2. Select the `glosos-macOS` scheme and your target Mac.
3. Build and run (`Cmd + R`).

### 2. Configuration & Setup

1. On first launch, complete the **Onboarding Setup**.
2. Open **Settings** (`Cmd + ,`) to select your **Runtime Mode**:
   - **Managed Container (Recommended)**: The app will download necessary kernel assets and automatically manage the Glosos backend container (`ghcr.io/basistiy/glosos-google-user:latest`).
   - **Manual Endpoint**: Specify a custom endpoint (e.g. `http://127.0.0.1:8000`).
3. Select your preferred **Model Provider** (Google Gemini, Cerebras, or Custom LLM) and supply your API keys or base URLs.
4. Click **Start Container** (or Connect) to initiate the local backend service.

---

## 🏗 Architecture

```
┌────────────────────────────────────────────────────────┐
│                      glosos-macOS                      │
│                                                        │
│  ┌───────────────────────┐   ┌──────────────────────┐  │
│  │     SwiftUI UI &      │   │   Voice & Audio      │  │
│  │   Onboarding Layer    │   │  (Silero VAD + TTS)  │  │
│  └───────────┬───────────┘   └──────────┬───────────┘  │
│              │                          │              │
│              ▼                          ▼              │
│  ┌──────────────────────────────────────────────────┐  │
│  │            AgentConnectionController             │  │
│  │    (HTTP Streaming / WebRTC Transport Layer)     │  │
│  └───────────────────────┬──────────────────────────┘  │
│                          │                             │
│                          ▼                             │
│  ┌──────────────────────────────────────────────────┐  │
│  │            LocalRuntimeController                │  │
│  │  (Apple Containerization API / Managed Engine)   │  │
│  └───────────────────────┬──────────────────────────┘  │
└──────────────────────────┼─────────────────────────────┘
                           │ VM / Vmnet
                           ▼
           ┌───────────────────────────────┐
           │   Linux Container Backend     │
           │  (ghcr.io/basistiy/glosos...) │
           └───────────────────────────────┘
```

---


## 📜 License

This project is released under the [MIT License](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/LICENSE).
