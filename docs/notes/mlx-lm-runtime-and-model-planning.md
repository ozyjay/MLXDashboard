# MLX-LM Runtime and Model Planning

These notes provide practical guidance for using `mlx-lm` with MLXDashboard on an Apple Silicon MacBook Pro with 64GB of unified memory.

Use this document when changing runtime startup, model discovery, install defaults, context budgeting, memory warnings, or agent-role presets. Model recommendations and runtime capabilities evolve quickly, so treat specific model choices and server options as starting points and verify them against the currently installed versions of MLX and the models being used.

## Core Idea

For local agentic development on Apple Silicon, MLX-native models should generally run through MLX and `mlx-lm` rather than Ollama.

Ollama remains useful for GGUF models and models distributed through the Ollama ecosystem, but Hugging Face `mlx-community` models are typically converted specifically for MLX and should be treated as MLX-native assets.

Useful mental model:

```text
Ollama        -> GGUF models, Ollama library models
mlx-lm        -> Hugging Face mlx-community models
mlx_lm.server -> Local OpenAI-compatible API server
```

For MLXDashboard, the primary runtime integration should be `mlx_lm.server`.

## `mlx_lm.server`

MLXDashboard should use `mlx_lm.server` as its standard MLX runtime integration. It provides a persistent OpenAI-compatible HTTP endpoint that can be used by MLXDashboard, Continue, OpenCode, Cline, and other agentic tooling.

Example:

```bash
mlx_lm.server \
  --model mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit \
  --host 127.0.0.1 \
  --port 8080
```

Client configuration:

```text
Base URL: http://localhost:8080/v1
API key: local
Model: mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
```

Security invariant: do not expose `mlx_lm.server` beyond localhost unless MLXDashboard deliberately adds a secured remote-access mode. The app should bind the managed server to `127.0.0.1` and should not allow user-provided server flags to override that binding. The official docs note that `mlx_lm.server` is not recommended for production use.

## Practical Memory Model for a 64GB Mac

A Mac with 64GB of unified memory should not be treated as though all 64GB is available for model weights and context.

Realistic working budget:

| Area | Approximate allowance |
| --- | --- |
| macOS and background services | 8-12GB |
| VS Code / Android Studio / browser / terminals | 6-12GB |
| Agent tools, file watchers, Node/Python processes | 2-6GB |
| Safety headroom | 4-8GB |
| Available for loaded models + KV cache | About 35-45GB, occasionally about 50GB on a lean system |

The model file size is only part of the story. Context length also consumes memory through the KV cache, and long contexts can become the dominant memory cost.

A model that is comfortable at 16K context may become significantly more memory-intensive at 128K context.

## Context-Size Guidance

Many modern models advertise context windows of 128K, 256K, or more. These values represent maximum capabilities, not necessarily practical defaults for a laptop.

Recommended defaults:

| Context size | Suggested use |
| --- | --- |
| 8K | Quick chat, small bug explanations, short file analysis |
| 16K | Safe default for local coding agents |
| 32K | Strong practical default for repository-aware work |
| 64K | Use selectively for larger planning or multi-file reasoning |
| 128K+ | Experimental; not recommended as a daily default |
| 256K | Treat as theoretical unless validated on the workload |

For MLXDashboard, a reasonable starting policy is:

```text
Default coding-agent context: 32K
Default planning context: 16K-32K
Default quick-ask context: 16K
Stretch-model context: 8K-16K initially
```

## Context Size in `mlx_lm.server`

At the time these notes were written, `mlx_lm.server` exposed common generation parameters such as:

- `max_tokens`
- `temperature`
- `top_p`
- `top_k`
- `min_p`
- repetition penalty
- presence penalty
- frequency penalty
- logit bias
- model selection
- adapters
- draft models
- draft tokens

`max_tokens` controls the number of output tokens generated, not the total context window. For example:

```json
{
  "max_tokens": 2048
}
```

means "generate up to 2048 output tokens." It does not mean "use a 2048-token context window."

MLXDashboard should therefore treat context management primarily as a client-side prompt budgeting problem:

- limit the number of included files;
- limit retrieved chunks;
- limit retained chat history;
- define context budgets per model;
- avoid sending prompts that exceed the practical limits of the selected model.

Do not assume that `mlx_lm.server` provides a direct equivalent to Ollama's `num_ctx` unless the installed version explicitly documents it.

MLXDashboard applies persisted per-role generation defaults for local provider aliases:

| Alias | Role | Temperature | Top P | Max tokens |
| --- | --- | --- | --- | --- |
| `mlx-ask` | Ask | 0.3 | 0.9 | 2048 |
| `mlx-plan` | Plan | 0.2 | 0.95 | 4096 |
| `mlx-coding` | Coding | 0.0 | 1.0 | 2048 |

These defaults fill in missing request parameters only. If a client sends `temperature`, `top_p`, or `max_tokens`, the client value wins.

Recommended diagnostic:

```bash
mlx_lm.server --help
```

Look for options such as:

```text
--max-kv-size
--kv-bits
--context-length
--max-context
--enable-thinking
--thinking-budget
```

If these options are unavailable, context management should remain a client-side responsibility.

## Recommended Model Roles

The most effective local agent setup is usually not a single model for every task. Assigning models to specific roles often produces better results.

Suggested roles:

1. Ask model
2. Planning model
3. Coding agent model
4. Verifier model
5. Stretch model

## Ask Model

The Ask model should be fast, responsive, and reasonably capable.

Use it for:

- explaining compiler errors;
- summarizing files;
- answering short coding questions;
- lightweight reasoning;
- quick troubleshooting prompts.

Recommended candidates:

```text
mlx-community/gpt-oss-20b-MXFP4-Q4
mlx-community/gpt-oss-20b-MXFP4-Q8
mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit
```

Suggested default:

```text
mlx-community/gpt-oss-20b-MXFP4-Q4
```

Suggested parameters:

```json
{
  "temperature": 0.3,
  "top_p": 0.9,
  "max_tokens": 2048,
  "stream": true
}
```

Suggested context budget:

```text
16K-32K
```

## Planning Model

The Planning model should be stronger than the Ask model and focus on structure, dependencies, and implementation sequencing before code changes are made.

Use it for:

- repository mapping;
- identifying affected files;
- implementation planning;
- task decomposition;
- risk analysis.

Recommended candidates:

```text
mlx-community/Qwen3.6-35B-A3B-4bit
mlx-community/Qwen3.6-35B-A3B-6bit
mlx-community/Qwen3.6-35B-A3B-4bit-DWQ
mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit
mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
```

Suggested default:

```text
mlx-community/Qwen3.6-35B-A3B-4bit
```

Alternative:

```text
mlx-community/Qwen3.6-35B-A3B-6bit
```

Use the alternative if memory usage and latency remain acceptable.

Suggested parameters:

```json
{
  "temperature": 0.2,
  "top_p": 0.95,
  "max_tokens": 4096,
  "stream": true
}
```

Suggested context budget:

```text
16K-32K
```

## Coding Agent Model

The Coding Agent model should be the most reliable model for repository navigation, multi-file edits, and tool-driven workflows.

Use it for:

- implementing features;
- editing multiple files;
- fixing tests;
- following project conventions;
- generating patches;
- resolving build failures.

Recommended candidates:

```text
mlx-community/mistralai_Devstral-Small-2-24B-Instruct-2512-MLX-8Bit
mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit
```

Suggested default:

```text
mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
```

The 6-bit version is a good balance between quality and memory usage on a 64GB machine. Use the 8-bit version when quality is more important than memory headroom and context requirements are modest.

Suggested parameters:

```json
{
  "temperature": 0.0,
  "top_p": 1.0,
  "max_tokens": 2048,
  "stream": true
}
```

Suggested context budget:

```text
32K
```

For larger tasks:

```text
64K only when necessary
```

## Verifier Model

The Verifier model should review outputs from the coding agent. Ideally, it should come from a different model family to increase the chance of catching different failure modes.

Use it for:

- reviewing diffs;
- identifying likely bugs;
- finding missing tests;
- checking adherence to project conventions;
- detecting over-editing;
- identifying hallucinated files or APIs.

Recommended candidates:

```text
mlx-community/gpt-oss-20b-MXFP4-Q8
mlx-community/gpt-oss-20b-MXFP4-Q4
mlx-community/Qwen3.6-35B-A3B-4bit
mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit
```

Suggested default:

```text
mlx-community/gpt-oss-20b-MXFP4-Q8
```

Suggested parameters:

```json
{
  "temperature": 0.0,
  "top_p": 1.0,
  "max_tokens": 2048,
  "stream": true
}
```

Suggested context budget:

```text
16K-32K
```

## Stretch Model

The Stretch model is intended for difficult tasks and experimentation. It should not be loaded by default.

Use it for:

- repository-wide changes;
- complex architecture discussions;
- ambiguous debugging sessions;
- benchmark experiments;
- comparison against the primary coding agent.

Recommended candidate:

```text
mlx-community/Qwen3-Coder-Next-4bit
```

This is a larger coding-focused model and should generally be treated as a one-model-at-a-time workload on a 64GB machine.

Suggested parameters:

```json
{
  "temperature": 0.0,
  "top_p": 1.0,
  "max_tokens": 2048,
  "stream": true
}
```

Suggested context budget:

```text
Start at 8K-16K
Try 32K only after validating memory usage
Avoid 64K+ unless deliberately stress-testing
```

## Suggested MLXDashboard Presets

MLXDashboard can expose presets rather than requiring users to manually evaluate every model.

### Balanced Local Agent

```yaml
name: Balanced Local Agent
ask:
  runtime: mlx_lm.server
  model: mlx-community/gpt-oss-20b-MXFP4-Q4
  contextLength: 16384
  temperature: 0.3
  topP: 0.9
  maxTokens: 2048

plan:
  runtime: mlx_lm.server
  model: mlx-community/Qwen3.6-35B-A3B-4bit
  contextLength: 32768
  temperature: 0.2
  topP: 0.95
  maxTokens: 4096

agent:
  runtime: mlx_lm.server
  model: mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
  contextLength: 32768
  temperature: 0.0
  topP: 1.0
  maxTokens: 2048

verifier:
  runtime: mlx_lm.server
  model: mlx-community/gpt-oss-20b-MXFP4-Q8
  contextLength: 16384
  temperature: 0.0
  topP: 1.0
  maxTokens: 2048
```

### Conservative

```yaml
name: Conservative
ask:
  runtime: mlx_lm.server
  model: mlx-community/gpt-oss-20b-MXFP4-Q4
  contextLength: 16384
  temperature: 0.3
  topP: 0.9
  maxTokens: 2048

plan:
  runtime: mlx_lm.server
  model: mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
  contextLength: 16384
  temperature: 0.2
  topP: 0.95
  maxTokens: 4096

agent:
  runtime: mlx_lm.server
  model: mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
  contextLength: 32768
  temperature: 0.0
  topP: 1.0
  maxTokens: 2048

verifier:
  runtime: mlx_lm.server
  model: mlx-community/gpt-oss-20b-MXFP4-Q4
  contextLength: 16384
  temperature: 0.0
  topP: 1.0
  maxTokens: 2048
```

### Experimental

```yaml
name: Experimental
ask:
  runtime: mlx_lm.server
  model: mlx-community/gpt-oss-20b-MXFP4-Q4
  contextLength: 16384
  temperature: 0.3
  topP: 0.9
  maxTokens: 2048

plan:
  runtime: mlx_lm.server
  model: mlx-community/Qwen3.6-35B-A3B-6bit
  contextLength: 32768
  temperature: 0.2
  topP: 0.95
  maxTokens: 4096

agent:
  runtime: mlx_lm.server
  model: mlx-community/Qwen3-Coder-Next-4bit
  contextLength: 16384
  temperature: 0.0
  topP: 1.0
  maxTokens: 2048

verifier:
  runtime: mlx_lm.server
  model: mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit
  contextLength: 16384
  temperature: 0.0
  topP: 1.0
  maxTokens: 2048
```

## Recommended Server Commands

These examples are useful diagnostics and manual reference commands. MLXDashboard should continue to bind managed server processes to `127.0.0.1`.

### Devstral Coding Agent

```bash
mlx_lm.server \
  --model mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit \
  --host 127.0.0.1 \
  --port 8080
```

### Qwen Planning Model

```bash
mlx_lm.server \
  --model mlx-community/Qwen3.6-35B-A3B-4bit \
  --host 127.0.0.1 \
  --port 8081
```

### GPT-OSS Ask/Verifier Model

```bash
mlx_lm.server \
  --model mlx-community/gpt-oss-20b-MXFP4-Q4 \
  --host 127.0.0.1 \
  --port 8082
```

### Stretch Model

```bash
mlx_lm.server \
  --model mlx-community/Qwen3-Coder-Next-4bit \
  --host 127.0.0.1 \
  --port 8083
```

MLXDashboard should not automatically start all of these simultaneously on a 64GB system. Prefer one default model server at a time, or at most one primary model plus a lightweight helper model.

## How Many Models Should Run at Once?

Downloaded models are rarely the problem. Loaded models are.

Recommended policy:

| Combination | Recommendation |
| --- | --- |
| One 24B-35B model | Good default |
| One 24B-35B model plus embeddings | Good default |
| One 20B helper plus one 24B agent | Usually acceptable with moderate context |
| Devstral plus Qwen3.6 loaded simultaneously | Avoid as a default |
| Qwen3-Coder-Next plus another large model | Avoid |
| Two 35B-class models | Avoid |
| 80B-class stretch model | Run alone |

For MLXDashboard:

```text
Prefer one active generation model at a time.
Warn when users attempt to start two large models.
Strongly warn when one of the models is Qwen3-Coder-Next.
```

## Suggested MLXDashboard Memory Warnings

MLXDashboard can classify models by approximate runtime footprint and display warnings accordingly.

Example categories:

```yaml
memoryClasses:
  small:
    description: "Comfortable helper model"
    examples:
      - gpt-oss-20b Q4
    defaultContext: 16384

  medium:
    description: "Daily coding/planning model"
    examples:
      - Devstral Small 2 6bit
      - Qwen3.6 35B 4bit
    defaultContext: 32768

  large:
    description: "Run deliberately with headroom"
    examples:
      - Devstral Small 2 8bit
      - Qwen3.6 35B 6bit
    defaultContext: 16384

  stretch:
    description: "One-model-at-a-time experimental workload"
    examples:
      - Qwen3-Coder-Next 4bit
    defaultContext: 8192
```
