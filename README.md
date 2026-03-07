# CrimsonWeb

# CrimsonWeb – Bug Bounty Automation Framework

CrimsonWeb is a powerful, modular, and highly customizable Bash-based reconnaissance and vulnerability scanning framework designed specifically for bug bounty hunters, penetration testers, and security researchers who want full control without heavy dependencies.It transforms fragmented tools into a unified, high-intensity pipeline with real-time C2 integration via Telegram.

Built for Parrot OS (and compatible with Kali/Debian-based systems), CrimsonWeb automates the entire bug bounty workflow — from target acquisition and passive/active reconnaissance through crawling, parameter discovery, JavaScript analysis, secret extraction, subdomain takeover checks, port scanning, vulnerability probing (XSS, SQLi, etc.), screenshotting, and final loot reporting.

# ⚡ Features at a Glance
Modular Orchestration: Logic split into core/ (Phases) and lib/ (Utilities) for maximum stability.

The "High Alert" Pipeline: A specialized filter that snipes sensitive endpoints (.env, api-keys, backups) and triggers immediate priority alerts.

Live Data Streaming: Real-time tail -f log sampling—watch the raw data flow without terminal clutter.

Asynchronous Processing: Smart job limiting based on system RAM and CPU load to prevent VPS crashes.

Telegram C2: Remote command and control. Receive "Loot Alerts" and control the scan via mobile.

Self-Healing Engine: Automatic Amass DB cleanup and PID-tracking to prevent "Zombie" processes.

# 🏗️ The Pipeline Architecture
CrimsonWeb moves in a strict linear sequence to ensure no data is missed:

RECON: Subdomain enumeration (Amass, Subfinder, Assetfinder).

SURFACE: Asset validation and port mapping (HTTPX, Naabu).

CRAWL: Deep URL discovery and historical harvesting (Katana, GAU, Wayback).

ANALYZE: Javascript secret extraction and parameter mining (Mantra, SubJS).

VULNS: Targeted vulnerability probing (Nuclei, Dalfox, Ghauri).

# 🚀 Installation & Setup
1. Requirements
OS: Ubuntu 20.04+ (Recommended)

Languages: Go 1.21+, Python 3.9+

Essential Tools: httpx, nuclei, amass, katana, naabu, ffuf.

2. Quick Start
Bash
￼
git clone https://github.com/crimsonej/crimsonweb.git
cd crimsonweb
chmod +x setup.sh crimsonweb.sh
./setup.sh
3. Configuration
Edit config/settings.conf to add your Telegram Bot Token and Chat ID to enable the C2 "High Alert" features.

⌨️ Usage

./crimsonweb.sh 

# ☢️ The High Alert System
The engine monitors every URL discovered for "Gold Mine" keywords. When a match is found, the data is diverted to the vault/TARGET/HIGH_ALERTS/ directory and pushed to your Telegram:

Keyword	Priority	Action
config/bak	CRITICAL	Full File Download
api/v1/keys	HIGH	Secret Entropy Scan
admin/login	MEDIUM	Fingerprint Analysis
￼
# 🛠️ Built With
Logic: Bash (Modularized)

Core Tools: ProjectDiscovery Suite, OWASP Amass

C2: Telegram Bot API

UI: ANSI Escape Sequences & Tmux Integration

# Philosophy
CrimsonWeb prioritizes transparency, speed, and zero external runtime dependencies (no Python/Node/Electron bloat). Everything is Bash-native, configurable via environment variables/flags, and extensible with custom phases or tools.

# Ideal for:

Solo bug hunters running long-term campaigns
Red-teamers needing reliable automation on resource-constrained systems
Researchers who want to understand and modify every line of their tooling

# Current status:
Actively developed (v3.x series as of March 2026).

# ⚖️ Disclaimer
CrimsonWeb is intended for authorized security auditing and bug bounty hunting only. I assumes no liability for misuse or damage caused by this tool. Always act within the bounds of the law and the specific program's rules of engagement
