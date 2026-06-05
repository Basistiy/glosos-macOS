# Apple Containerization Runtime Plan (Transport-Agnostic)

## Summary

- Replace the app's dependency on Apple's `container` CLI with Apple's `Containerization` Swift APIs so the app owns container lifecycle directly.
- Do not carry forward any WebSocket assumptions. The current agent connection layer must be refactored into a transport-agnostic abstraction because the container no longer uses `ws`.
- Optimize for a signed direct-download macOS app on Apple silicon and macOS 26+, with first-run kernel/init setup handled inside the app.

## Key Changes

- Keep `LocalRuntimeController` as the UI-facing runtime controller, but replace its CLI execution path with a `ContainerizationRuntimeEngine` built on `ContainerManager`, `VmnetNetwork`, `ImageStore`, and a managed app support directory.
- Add a transport boundary between runtime and agent I/O:
  - replace the current WebSocket-shaped assumptions in `glosos-macOS/AgentConnectionController.swift` with an `AgentTransport` protocol
  - move connection state, send, stream, and disconnect behavior behind that protocol
  - remove `socketURL` as the managed-runtime contract; managed mode should instead consume a runtime-provided endpoint/config object
- Treat the container protocol as a required contract to revise during implementation:
  - the plan must not assume `ws://127.0.0.1:18000/ws`
  - implementation should first map the new backend interface, then add the matching transport adapter
  - manual mode should also become transport-aware rather than "manual WebSocket"
- Add in-app runtime asset provisioning:
  - download the recommended Linux kernel from the same source Apple's `container` project uses by default
  - pin `apple/containerization` to a tagged release and use the matching `ghcr.io/apple/containerization/vminit:<tag>` init image
  - store kernel, image data, container state, and logs under `Application Support/Glosos/Containerization/`
- Start the backend container through `ContainerManager` using:
  - `Kernel(path: ..., platform: .linuxArm)`
  - `initfsReference: pinnedVminitReference`
  - `network: VmnetNetwork()`
  - image `ghcr.io/basistiy/glosos-google-user:latest`
- Change managed runtime readiness from "localhost WebSocket reachable" to "runtime-provided endpoint ready":
  - once the container starts, capture the assigned container IP and whatever port/protocol mapping the new backend requires
  - if the backend still expects host-local access, add a small host-side relay only after the new protocol is known
  - otherwise let the app connect directly to the container IP
- Update settings and status UI:
  - rename "Manual WebSocket" to a protocol-neutral manual mode
  - replace "Computed WebSocket URL" with runtime endpoint/status text
  - show staged setup progress such as kernel download, init image pull, vmnet startup, container launch, and endpoint ready
- Update distribution/configuration:
  - keep App Sandbox off
  - add the virtualization entitlement required by Containerization-backed apps
  - document that this path targets direct-download distribution, not Mac App Store shipping

## Public Interfaces / Types

- Replace `socketURL`-centric managed-runtime APIs with a `ManagedRuntimeEndpoint` type that can carry protocol, host, port, and any path or request metadata required by the backend.
- Add `AgentTransport` with operations for `connect`, `disconnect`, `send`, and streamed/non-streamed response handling.
- Change `RuntimeMode` labels from transport-specific wording to protocol-neutral wording while preserving migration for existing saved settings.
- Add `ContainerAssetManaging` and `ContainerRuntimeManaging` protocols so runtime setup, asset provisioning, and container lifecycle stay testable.

## Test Plan

- Unit tests for runtime support:
  - unsupported on Intel
  - unsupported below macOS 26
  - unsupported when app runtime storage cannot be created
- Unit tests for asset provisioning:
  - first launch downloads kernel and pulls init image
  - subsequent launches reuse matching assets
  - provisioning failures surface actionable UI errors
- Unit tests for transport decoupling:
  - managed runtime no longer hardcodes `ws://...`
  - agent controller can operate through a fake `AgentTransport`
  - manual mode persists protocol-neutral endpoint settings
- Unit tests for runtime lifecycle:
  - managed start reaches `.running` only after the container endpoint is ready
  - stop/restart clean up container state and any host relay if used
- Manual acceptance checks:
  - first launch on a clean machine needs no `container` CLI install
  - the app surfaces the runtime endpoint correctly
  - the container connection protocol is revised from the current WebSocket implementation before managed mode is considered complete

## Assumptions And Defaults

- The backend image remains `ghcr.io/basistiy/glosos-google-user:latest`, public, and runnable as a Linux arm64 workload on Apple silicon.
- The protocol of connection to the container needs to be revised; this plan intentionally does not assume WebSocket compatibility.
- The app targets signed direct-download distribution outside the Mac App Store.
- `Containerization` is pinned to a tagged release and uses the matching `vminit` image tag to avoid version drift.
- Development should avoid running from `Documents` or `Desktop` while the current macOS 26 vmnet location bug exists.
