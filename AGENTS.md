## Global Development Preferences

- This machine uses `pyenv` for Python. In all projects, prefer `python3` from the active `pyenv` version when creating virtual environments, installing packages, or running Python tooling. Avoid assuming the macOS system Python is the intended interpreter.

## MLXDashboard Project Guidance

- Before changing runtime startup, server flags, model discovery, model install defaults, context budgeting, memory warnings, or model-role presets, consult `docs/notes/mlx-lm-runtime-and-model-planning.md`.
- Keep the managed `mlx_lm.server` bound to `127.0.0.1` unless a deliberate secured remote-access mode is designed and implemented. Do not allow persisted settings or user-provided server flags to expose it beyond localhost.
- When changing model-management UX, consult `docs/notes/ollama-lessons-for-mlx-dashboard.md` for the current direction on Discover, Installed/cache management, status rows, and dense table-first workflows.
