from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
from typing import Any, Mapping
import uuid

from .runtime import RuntimeRequestError, TextDiffusionProvider


LOGGER = logging.getLogger("mlxdashboard.text_diffusion")
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


class RuntimeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], provider: TextDiffusionProvider):
        super().__init__(address, RuntimeRequestHandler)
        self.provider = provider


class RuntimeRequestHandler(BaseHTTPRequestHandler):
    server: RuntimeHTTPServer

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/health":
            self._json(200, {"status": "ok", **self.server.provider.capabilities()})
            return
        if path == "/v1/models":
            capabilities = self.server.provider.capabilities()
            self._json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": self.server.provider.model_id,
                            "object": "model",
                            "created": 0,
                            "owned_by": "local",
                            "generation_type": "text",
                            "model_family": "diffusion_text",
                            "state": "loaded",
                            **capabilities,
                        }
                    ],
                },
            )
            return
        if path == "/provider/v1/runtime":
            self._json(200, self.server.provider.capabilities())
            return
        self._error(404, "not found")

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path != "/v1/chat/completions":
            self._error(404, "not found")
            return
        try:
            payload = self._payload()
            if payload.get("stream") is True:
                self._error(
                    400,
                    "streaming is not supported by the text diffusion runtime; use stream=false",
                )
                return
            result = self.server.provider.chat_completion(payload)
            self._json(
                200,
                {
                    "id": f"chatcmpl-{uuid.uuid4().hex}",
                    "object": "chat.completion",
                    "model": self.server.provider.model_id,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": result.text},
                            "finish_reason": result.finish_reason,
                        }
                    ],
                    "usage": {
                        "prompt_tokens": result.prompt_tokens,
                        "completion_tokens": result.completion_tokens,
                        "total_tokens": result.prompt_tokens + result.completion_tokens,
                    },
                    "diffusion": {
                        "mode": result.mode,
                        "steps": result.steps,
                        "block_length": result.block_length,
                        "nfe": result.nfe,
                        "elapsed_seconds": result.elapsed_seconds,
                    },
                },
            )
        except RuntimeRequestError as exc:
            self._error(400, str(exc))
        except json.JSONDecodeError:
            self._error(400, "request body must be valid JSON")
        except Exception as exc:
            LOGGER.exception("text diffusion request failed")
            self._error(500, f"text diffusion generation failed: {exc}")

    def _payload(self) -> Mapping[str, Any]:
        length = int(self.headers.get("content-length", "0"))
        if length <= 0:
            raise RuntimeRequestError("request body is required")
        value = json.loads(self.rfile.read(length))
        if not isinstance(value, dict):
            raise RuntimeRequestError("request body must be an object")
        return value

    def _error(self, status: int, message: str) -> None:
        self._json(status, {"error": {"message": message, "type": "text_diffusion_error"}})

    def _json(self, status: int, value: object) -> None:
        body = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        LOGGER.info("%s - %s", self.address_string(), format % args)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="MLXDashboard text diffusion server")
    parser.add_argument("--model", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument(
        "--trust-remote-code",
        action=argparse.BooleanOptionalAction,
        default=True,
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.host not in LOOPBACK_HOSTS:
        raise SystemExit("the text diffusion runtime only accepts loopback hosts")
    logging.basicConfig(level=logging.INFO)
    provider = TextDiffusionProvider(
        args.model,
        trust_remote_code=args.trust_remote_code,
    )
    server = RuntimeHTTPServer((args.host, args.port), provider)
    LOGGER.info(
        "text diffusion runtime ready model=%s host=%s port=%s modes=%s",
        args.model,
        args.host,
        args.port,
        sorted(provider.supported_modes),
    )
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
