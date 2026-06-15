# MLXDashboard

Native macOS SwiftUI dashboard for owning a local `mlx-lm` server, installing MLX-compatible Hugging Face models, and exposing an OpenAI-compatible localhost provider for MLXChat.

## Project Notes

- [MLX-LM runtime and model planning](docs/notes/mlx-lm-runtime-and-model-planning.md): runtime choice, localhost-only server binding, context budgeting, model-role presets, and 64GB memory guidance.
- [Ollama lessons for MLXDashboard](docs/notes/ollama-lessons-for-mlx-dashboard.md): UX and architecture lessons to apply from OllamaPull and OllamaAgent.

## MLXChat Provider Contract

MLXDashboard exposes a localhost-only provider for MLXChat. `/v1/models` and its `/api/v1/models` compatibility spelling remain the OpenAI-compatible model list used for normal chat routing and role aliases, and only advertise runnable provider models: the mode aliases plus the active runnable local model. `/provider/v1/models` and `/provider/v1/models/{model}` are the MLXDashboard-specific metadata routes for model capability and availability. The older `/api/v0/models` and `/api/v0/models/{model}` routes remain as legacy aliases for earlier local clients. These metadata routes include optional capability metadata for advertised models, and may also include known non-runnable models so clients can show an explanatory unavailable state. Loaded metadata-only catalogue or registry entries are not advertised unless they are the active provider model:

- `generation_type: "text"`
- `model_family: "chat"` for normal chat/LLM models
- `model_family: "diffusion_text"` for runnable text diffusion models such as `diffusion_gemma`
- `state: "loaded"` for runnable models
- `state: "unsupported"` with `reason` and `unsupported_reason` when the installed runtime cannot serve the model
- `state: "not_installed"` with `reason` and `not_installed_reason` when a configured provider model is not available in the local cache

Text diffusion models are text-generation models in this provider contract. They remain chat-completions-compatible when runnable; MLXDashboard does not expose image generation or `/v1/images/generations`.
