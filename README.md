# MLXDashboard

Native macOS SwiftUI dashboard for owning a local `mlx-lm` server, installing MLX-compatible Hugging Face models, and exposing an OpenAI-compatible localhost provider for MLXChat.

## Project Notes

- [MLX-LM runtime and model planning](docs/notes/mlx-lm-runtime-and-model-planning.md): runtime choice, localhost-only server binding, context budgeting, model-role presets, and 64GB memory guidance.
- [Ollama lessons for MLXDashboard](docs/notes/ollama-lessons-for-mlx-dashboard.md): UX and architecture lessons to apply from OllamaPull and OllamaAgent.
- [Provider streaming and quality hardening plan](docs/superpowers/plans/2026-06-19-provider-streaming-and-quality.md): streamed provider regression tests, alias contract cleanup, localhost provider hardening, diagnostic-capture privacy, and CI coverage.

## MLXChat Provider Contract

MLXDashboard exposes a localhost-only provider for MLXChat. The MLXChat base URL is the provider root, for example `http://127.0.0.1:8123`; the OpenAI-compatible base URL is `http://127.0.0.1:8123/v1`.

```bash
swift run mlxchat --base-url http://127.0.0.1:8123 --json
```

`/v1/models` and its `/api/v1/models` compatibility spelling remain the OpenAI-compatible model list used for normal chat routing and role aliases, and only advertise runnable provider models: the canonical mode aliases plus the default runnable local model. The canonical aliases are:

- `mlx-ask`
- `mlx-plan`
- `mlx-coding`

`mlx-fast` remains accepted as a legacy compatibility alias for the coding role, but it is not advertised as canonical in model-list routes or new client configuration.

`/provider/v1/models` and `/provider/v1/models/{model}` are the MLXDashboard-specific metadata routes for model capability and availability. The older `/api/v0/models` and `/api/v0/models/{model}` routes remain as legacy aliases for earlier local clients. These metadata routes include optional capability metadata for advertised models, and may also include known non-runnable models so clients can show an explanatory unavailable state. Loaded metadata-only catalogue or registry entries are not advertised unless they are the default provider model:

- `runtime`, such as `"mlx_lm"` or `"text_diffusion"`
- `model_type`, when known from runtime metadata
- `supports_streaming`
- `supported_generation_modes`
- `max_context_length`, when known from runtime metadata
- `max_output_tokens`, when known from runtime metadata
- `effective_model`, `routing_state`, `effective_port`, and `fallback_reason` for role alias routing metadata when applicable
- `generation_type: "text"`
- `model_family: "chat"` for normal chat/LLM models
- `model_family: "diffusion_text"` for runnable text diffusion models such as `diffusion_gemma`
- `state: "loaded"` for runnable models
- `state: "unsupported"` with `reason` and `unsupported_reason` when the installed runtime cannot serve the model
- `state: "not_installed"` with `reason` and `not_installed_reason` when a configured provider model is not available in the local cache

Text diffusion models are text-generation models in this provider contract. They remain chat-completions-compatible when runnable; MLXDashboard does not expose image generation or `/v1/images/generations`.
