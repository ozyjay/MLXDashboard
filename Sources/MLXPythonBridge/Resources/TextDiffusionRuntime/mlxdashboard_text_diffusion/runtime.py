from __future__ import annotations

from dataclasses import dataclass
import inspect
import json
import threading
import time
from typing import Any, Mapping, Sequence

import mlx.core as mx
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler


class RuntimeRequestError(RuntimeError):
    pass


@dataclass(frozen=True)
class DiffusionOptions:
    mode: str = "diffusion"
    steps: int = 64
    block_length: int = 32
    threshold: float = 0.9
    algorithm: str = "entropy"
    seed: int | None = None

    @classmethod
    def from_value(cls, value: object) -> "DiffusionOptions":
        if value is None:
            return cls()
        if not isinstance(value, Mapping):
            raise RuntimeRequestError("mlx_diffusion must be an object")
        mode = str(value.get("mode", "diffusion"))
        if mode not in {"diffusion", "linear_spec", "autoregressive"}:
            raise RuntimeRequestError("unsupported mlx_diffusion.mode")
        return cls(
            mode=mode,
            steps=_bounded_int(value.get("steps", 64), "steps", 1, 4096),
            block_length=_bounded_int(value.get("block_length", 32), "block_length", 1, 4096),
            threshold=_bounded_float(value.get("threshold", 0.9), "threshold", 0, 1),
            algorithm=str(value.get("algorithm", "entropy")).strip() or "entropy",
            seed=None if value.get("seed") is None else int(value["seed"]),
        )


@dataclass(frozen=True)
class GenerationResult:
    text: str
    prompt_tokens: int
    completion_tokens: int
    finish_reason: str
    elapsed_seconds: float
    mode: str
    steps: int | None
    block_length: int | None
    nfe: int | None


class TextDiffusionProvider:
    def __init__(self, model_id: str, trust_remote_code: bool = True) -> None:
        if not model_id:
            raise ValueError("model_id is required")
        self.model_id = model_id
        self._lock = threading.Lock()
        self.model, self.tokenizer = load(
            model_id,
            trust_remote_code=trust_remote_code,
            tokenizer_config={"trust_remote_code": trust_remote_code},
        )
        if hasattr(self.model, "eval"):
            self.model.eval()
        self.model_type = self._model_type()
        self.supported_modes = self._supported_modes()

    def capabilities(self) -> dict[str, Any]:
        return {
            "runtime": "text_diffusion",
            "model": self.model_id,
            "model_type": self.model_type,
            "supports_streaming": False,
            "supported_generation_modes": sorted(self.supported_modes),
            "mode_advice_strategy": "heuristic",
        }

    def chat_completion(self, payload: Mapping[str, Any]) -> GenerationResult:
        messages = payload.get("messages")
        if not isinstance(messages, list) or not messages:
            raise RuntimeRequestError("messages must be a non-empty array")

        advice = _mode_advice_result(messages)
        if advice is not None:
            text = json.dumps(advice, separators=(",", ":"))
            prompt_text = "\n".join(
                str(message.get("content", ""))
                for message in messages
                if isinstance(message, Mapping)
            )
            return GenerationResult(
                text=text,
                prompt_tokens=len(self._encode(prompt_text)),
                completion_tokens=len(self._encode(text)),
                finish_reason="stop",
                elapsed_seconds=0,
                mode="heuristic",
                steps=None,
                block_length=None,
                nfe=0,
            )

        prompt = self._render_chat(messages)
        prompt_ids = self._encode(prompt)
        max_tokens = _bounded_int(payload.get("max_tokens", 256), "max_tokens", 1, 32768)
        temperature = _bounded_float(payload.get("temperature", 0), "temperature", 0, 2)
        top_p = _bounded_float(payload.get("top_p", 1), "top_p", 0, 1)
        top_k = _bounded_int(payload.get("top_k", 0), "top_k", 0, 1_000_000)
        min_p = _bounded_float(payload.get("min_p", 0), "min_p", 0, 1)
        options = DiffusionOptions.from_value(payload.get("mlx_diffusion"))
        stop = _stop_sequences(payload.get("stop"))

        started = time.perf_counter()
        with self._lock:
            if options.seed is not None:
                mx.random.seed(options.seed)
            if options.mode == "autoregressive":
                text, count = self._autoregressive(
                    prompt, max_tokens, temperature, top_p, top_k, min_p
                )
                steps = block_length = nfe = None
            else:
                text, count, nfe = self._diffusion(
                    prompt_ids, max_tokens, options, temperature, top_p, top_k, min_p
                )
                steps = options.steps
                block_length = options.block_length

        text, stopped = _apply_stop(text, stop)
        return GenerationResult(
            text=text.strip(),
            prompt_tokens=len(prompt_ids),
            completion_tokens=count,
            finish_reason="stop" if stopped or count < max_tokens else "length",
            elapsed_seconds=time.perf_counter() - started,
            mode=options.mode,
            steps=steps,
            block_length=block_length,
            nfe=nfe,
        )

    def _autoregressive(
        self,
        prompt: str,
        max_tokens: int,
        temperature: float,
        top_p: float,
        top_k: int,
        min_p: float,
    ) -> tuple[str, int]:
        sampler = _sampler(temperature, top_p, top_k, min_p)
        text = generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
            verbose=False,
        )
        text = text if isinstance(text, str) else str(text)
        return text, len(self._encode(text))

    def _diffusion(
        self,
        prompt_ids: list[int],
        max_tokens: int,
        options: DiffusionOptions,
        temperature: float,
        top_p: float,
        top_k: int,
        min_p: float,
    ) -> tuple[str, int, int | None]:
        if options.mode not in self.supported_modes:
            raise RuntimeRequestError(
                f"{options.mode} is unavailable; supported modes: {sorted(self.supported_modes)}"
            )
        names = (
            ("linear_spec_generate", "linear_speculation_generate")
            if options.mode == "linear_spec"
            else ("diffusion_generate", "generate")
        )
        method = next(
            (getattr(self.model, name) for name in names if callable(getattr(self.model, name, None))),
            None,
        )
        if method is None:
            raise RuntimeRequestError(f"model has no {options.mode} generation method")

        candidates = {
            "max_new_tokens": max_tokens,
            "max_tokens": max_tokens,
            "steps": options.steps,
            "num_steps": options.steps,
            "block_length": options.block_length,
            "threshold": options.threshold,
            "algorithm": options.algorithm,
            "alg": options.algorithm,
            "temperature": temperature,
            "top_p": top_p,
            "top_k": top_k,
            "min_p": min_p,
            "eos_token_id": getattr(self.tokenizer, "eos_token_id", None),
        }
        output = method(
            mx.array([prompt_ids], dtype=mx.int32),
            **_accepted_kwargs(method, candidates),
        )
        token_ids, nfe = _token_ids(output)
        if token_ids[: len(prompt_ids)] == prompt_ids:
            token_ids = token_ids[len(prompt_ids) :]
        token_ids = _at_eos(token_ids[:max_tokens], getattr(self.tokenizer, "eos_token_id", None))
        return self._decode(token_ids), len(token_ids), nfe

    def _render_chat(self, messages: list[object]) -> str:
        normalized = []
        for value in messages:
            if not isinstance(value, Mapping):
                raise RuntimeRequestError("each message must be an object")
            role = str(value.get("role", "user"))
            if role == "developer":
                role = "system"
            elif role == "tool":
                role = "user"
            content = value.get("content", "")
            if not isinstance(content, str):
                content = str(content)
            normalized.append({"role": role, "content": content})

        template = getattr(self.tokenizer, "apply_chat_template", None)
        if callable(template):
            try:
                rendered = template(normalized, tokenize=False, add_generation_prompt=True)
                if isinstance(rendered, str):
                    return rendered
            except Exception:
                pass
        return "\n".join(
            [f"{item['role'].upper()}: {item['content']}" for item in normalized]
            + ["ASSISTANT:"]
        )

    def _encode(self, text: str) -> list[int]:
        try:
            return list(self.tokenizer.encode(text, add_special_tokens=False))
        except TypeError:
            return list(self.tokenizer.encode(text))

    def _decode(self, token_ids: Sequence[int]) -> str:
        try:
            return str(self.tokenizer.decode(list(token_ids), skip_special_tokens=True))
        except TypeError:
            return str(self.tokenizer.decode(list(token_ids)))

    def _model_type(self) -> str | None:
        for value in (
            getattr(self.model, "model_type", None),
            getattr(getattr(self.model, "args", None), "model_type", None),
        ):
            if isinstance(value, str) and value:
                return value
        return None

    def _supported_modes(self) -> set[str]:
        modes = {"autoregressive"}
        if callable(getattr(self.model, "diffusion_generate", None)):
            modes.add("diffusion")
        if callable(getattr(self.model, "linear_spec_generate", None)) or callable(
            getattr(self.model, "linear_speculation_generate", None)
        ):
            modes.add("linear_spec")
        marker = f"{self.model_type or ''} {self.model_id}".lower()
        if any(value in marker for value in ("diffusion", "llada", "dream", "diffucoder")) and callable(
            getattr(self.model, "generate", None)
        ):
            modes.add("diffusion")
        return modes


def _mode_advice_result(messages: list[object]) -> dict[str, object] | None:
    system_text = "\n".join(
        str(message.get("content", ""))
        for message in messages
        if isinstance(message, Mapping) and message.get("role") in {"system", "developer"}
    )
    if "Classify the user's request for a local coding assistant UI" not in system_text:
        return None
    user_text = "\n".join(
        str(message.get("content", ""))
        for message in messages
        if isinstance(message, Mapping) and message.get("role") == "user"
    ).lower()
    plan_terms = (
        "plan", "architecture", "design", "roadmap", "sequence", "decompose",
        "break down", "risk analysis", "implementation approach",
    )
    coding_terms = (
        "implement", "write code", "edit", "patch", "fix", "refactor", "test",
        "build", "compile", "create file", "change the code",
    )
    if any(term in user_text for term in coding_terms):
        mode = "coding"
        reason = "The request asks for code changes or implementation work."
    elif any(term in user_text for term in plan_terms):
        mode = "plan"
        reason = "The request asks for architecture, sequencing, or planning."
    else:
        mode = "ask"
        reason = "The request is explanatory or does not require code changes."
    return {"mode": mode, "confidence": 0.9, "reason": reason}


def _sampler(temperature: float, top_p: float, top_k: int, min_p: float) -> Any:
    signature = inspect.signature(make_sampler)
    values = {
        "temp": temperature,
        "temperature": temperature,
        "top_p": top_p,
        "top_k": top_k,
        "min_p": min_p,
    }
    return make_sampler(**{name: values[name] for name in signature.parameters if name in values})


def _accepted_kwargs(method: Any, candidates: Mapping[str, Any]) -> dict[str, Any]:
    signature = inspect.signature(method)
    accepts_any = any(p.kind == inspect.Parameter.VAR_KEYWORD for p in signature.parameters.values())
    return {
        name: value
        for name, value in candidates.items()
        if value is not None and (accepts_any or name in signature.parameters)
    }


def _token_ids(output: object) -> tuple[list[int], int | None]:
    nfe = None
    if isinstance(output, tuple):
        if len(output) > 1 and isinstance(output[1], (int, float)):
            nfe = int(output[1])
        output = output[0]
    if hasattr(output, "tolist"):
        mx.eval(output)
        value = output.tolist()
    elif isinstance(output, list):
        value = output
    else:
        value = list(output)  # type: ignore[arg-type]
    while len(value) == 1 and isinstance(value[0], list):
        value = value[0]
    if any(isinstance(item, list) for item in value):
        raise RuntimeRequestError("unexpected generated token shape")
    return [int(item) for item in value], nfe


def _at_eos(token_ids: list[int], eos: object) -> list[int]:
    eos_ids = {int(eos)} if isinstance(eos, int) else set()
    for index, token_id in enumerate(token_ids):
        if token_id in eos_ids:
            return token_ids[:index]
    return token_ids


def _stop_sequences(value: object) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    raise RuntimeRequestError("stop must be a string or array")


def _apply_stop(text: str, stops: Sequence[str]) -> tuple[str, bool]:
    indexes = [text.find(stop) for stop in stops if stop and text.find(stop) >= 0]
    return (text[: min(indexes)], True) if indexes else (text, False)


def _bounded_int(value: object, name: str, lower: int, upper: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise RuntimeRequestError(f"{name} must be an integer") from exc
    if not lower <= parsed <= upper:
        raise RuntimeRequestError(f"{name} must be between {lower} and {upper}")
    return parsed


def _bounded_float(value: object, name: str, lower: float, upper: float) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise RuntimeRequestError(f"{name} must be a number") from exc
    if not lower <= parsed <= upper:
        raise RuntimeRequestError(f"{name} must be between {lower} and {upper}")
    return parsed
