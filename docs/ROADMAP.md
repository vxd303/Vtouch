# Roadmap to Commercial-Grade Architecture

This document outlines the steps to refactor `zxtouch` from a simple Tweak into a robust Daemon-based automation platform.

## Phase 1: Architecture Refactor (The Daemon Split)
Goal: Move heavy logic out of SpringBoard to prevent crashes and improve stability.

- [ ] **Task 1.1: Create Daemon Skeleton (`zxtouchd`)**
    - [ ] Convert `zxtouch-binary` into a proper Daemon.
    - [ ] Configure `LaunchDaemon` plist to auto-start `zxtouchd` on boot (as root).
    - [ ] Ensure `zxtouchd` keeps running and doesn't exit.

- [ ] **Task 1.2: Migrate Socket Server**
    - [ ] Move `SocketServer.xm` logic from `pccontrol` to `zxtouchd`.
    - [ ] `zxtouchd` should listen on Port 6000.
    - [ ] `pccontrol` should STOP listening on Port 6000.

- [ ] **Task 1.3: Establish IPC (Inter-Process Communication)**
    - [ ] Implement a communication channel between `zxtouchd` (Daemon) and `pccontrol` (SpringBoard).
    - [ ] Recommended: `CFMessagePort` (Native, no external deps) or `CPDistributedMessagingCenter` (if AppSupport available).
    - [ ] Define protocol: e.g., Daemon receives `CMD_HOME`, sends IPC message to SB Tweak -> SB Tweak performs Home action.

- [ ] **Task 1.4: Refactor Image Processing**
    - [ ] Move `TemplateMatch.xm`, `OpenCV` dependency, and `TextRecognizer` to `zxtouchd`.
    - [ ] `zxtouchd` captures screen (via `IOMobileFramebuffer` or `IOSurface`), processes it, and returns result to Socket Client.
    - [ ] This frees up SpringBoard RAM/CPU.

## Phase 2: Security & Networking
Goal: Prevent unauthorized access.

- [ ] **Task 2.1: Socket Authentication**
    - [ ] Implement a "Handshake" packet. Client must send a password/token immediately after connecting.
    - [ ] Store password in `/var/mobile/Library/ZXTouch/auth.plist`.

- [ ] **Task 2.2: Protocol Upgrade**
    - [ ] Define a structured packet format (Header + Length + JSON Body).
    - [ ] Replace `;;` string splitting with JSON parsing.

## Phase 3: Advanced Features
Goal: Reach feature parity with commercial tools.

- [ ] **Task 3.1: Accessibility Support**
    - [ ] Create a helper to dump UI Hierarchy.
    - [ ] Implement `find_element_by_text` in Python client.

- [ ] **Task 3.2: Script Runtime**
    - [ ] Embed `LuaJIT` or Python into `zxtouchd` for high-performance local script execution.
