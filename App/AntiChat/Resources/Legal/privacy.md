---
title: Privacy
version: "0.1.0"
updated: "2026-11-17"
---

> **Draft.** This page is a draft awaiting legal review before the first public release.

- **No account, no telemetry.** AntiChat has no sign-in and sends no usage data.
- **Local storage.** Chats, pictures, files and models stay in `~/Library/Application Support/AntiChat` on your Mac.
- **What leaves your Mac, only when you use it:** web search words (to the search engine you chose), connector requests (through AntiChat's relay to Composio and the service you connected), model downloads (Hugging Face), and the daily update and catalog checks: new app versions and the model list (the app version, macOS version and chip type, no identifier). The list of skills is refreshed from AntiChat's public skills index on GitHub, at most once a day, starting the first time you open Settings › Skills; nothing about you is sent. When you open Settings › Connections, or a chat offers to connect an app, the list of apps you can connect is fetched from AntiChat's connection service, at most once a day; once you have connected an app it is also refreshed daily in the background. Nothing about you is sent beyond what connecting already sends (the app version and a random install identifier), and the logos of newly listed apps are loaded from Composio. Never in Offline only.
- **This website** sets no cookies and loads no third-party scripts. We only see aggregate download counts from our host, never who downloaded.
- **Crash reports** are sent only if you click Send after a crash, and you can read them first.
