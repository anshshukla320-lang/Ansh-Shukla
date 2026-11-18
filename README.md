# PeakCut + SupoClip setup

One-command setup for two open-source tools that turn long videos into short vertical clips:

| App | Repo | Opens at | Needs |
|---|---|---|---|
| **PeakCut** | [haziqahmedqasmi/PeakCut](https://github.com/haziqahmedqasmi/PeakCut) | http://127.0.0.1:8765 | Python 3.10+, ffmpeg. An AI key is optional (set in the dashboard). |
| **SupoClip** | [FujiwaraChoki/supoclip](https://github.com/FujiwaraChoki/supoclip) | http://localhost:3107 | PostgreSQL, Redis, Node 20+, ffmpeg, Tesseract, plus an AssemblyAI key and one AI key. |

The apps themselves are not copied here. `setup.sh` downloads the latest version of each.

## Install (Linux or macOS)

```bash
git clone https://github.com/anshshukla320-lang/Ansh-Shukla.git ~/clip-setup
```

```bash
cd ~/clip-setup && ./setup.sh all
```

This puts the apps in `~/peakcut` and `~/supoclip`. To install them somewhere else, set `INSTALL_DIR=/some/folder` before
the command. The script installs missing system packages with `apt` (Linux) or Homebrew (macOS). It also installs `uv`
and `pnpm` if needed, sets up SupoClip's database and writes its settings files with fresh random secrets. You can run it again safely.

Only want one? Use `./setup.sh peakcut` or `./setup.sh supoclip`.

On Windows, use WSL (Ubuntu) and run the same commands. You can also follow each app's own README.

## Add your keys

- **PeakCut**: open http://127.0.0.1:8765, go to **Settings, AI**, pick a service and paste a key. Without a key it
  still picks clips by loudness.
- **SupoClip**: edit `~/supoclip/backend/.env` and fill in `ASSEMBLY_AI_API_KEY` and an AI key. The default is
  `GOOGLE_API_KEY` with `LLM=google-gla:gemini-3-flash-preview`. `~/supoclip/.env.example` lists other providers.
  Then restart SupoClip.

## Start and stop

```bash
./start.sh all
```

```bash
./start.sh stop
```

`./start.sh peakcut` or `./start.sh supoclip` starts just one. Logs: `~/peakcut/peakcut.log`,
`~/supoclip/{backend,worker,frontend}.log`.

In SupoClip, create an account on the sign-up page the first time.

## SupoClip with Docker instead

If you have Docker, this skips installing Postgres, Redis and Node on your machine:

```bash
./setup.sh supoclip-docker
```

Then add your keys to `~/supoclip/.env` and run `docker compose up -d --build` in `~/supoclip`.

## Notes

- SupoClip's repo has no automatic database migrator. `setup.sh` loads `init.sql`, applies every file in
  `backend/src/migrations/sql/` (they are safe to re-apply) and one Prisma change the others lack. It then warns you
  if the website's schema still expects something the database doesn't have.
- If the PyTorch CPU download is blocked, SupoClip's backend installs without PyTorch. Transcription through AssemblyAI
  still works. Only local Whisper needs PyTorch.
- **Licenses:** PeakCut is open source (see its LICENSE). SupoClip uses the *SupoClip Noncommercial Source
  License*: personal, noncommercial self-hosting only. Business use needs written permission from Shiori LLC.
- Keys and `.env` files live inside the app folders, never in this repo.
