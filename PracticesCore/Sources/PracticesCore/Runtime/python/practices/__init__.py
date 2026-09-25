"""Helpers a practice may import. Everything here works only inside Practices' runner.

    from practices import use, update_secret

    telemetry = use("xkdb/get-chunk-multi")   # another practice, called like a function
    update_secret("FALLBACK_X_TOKEN", new)     # a rotated token goes back to the store
"""
from __future__ import annotations

import asyncio
import importlib.util
import inspect
import os
import threading
import time
from pathlib import Path
from typing import Any, Callable

from . import _shape

REGISTRY = Path(os.environ.get("PRACTICES_REGISTRY", str(Path.home() / ".practices" / "registry")))

#: Filled by `use()` wrappers; the runner reports it as the run's steps.
STEPS: list[dict[str, Any]] = []
#: Filled by `update_secret()`; Practices writes them to the secret store after the run.
SECRET_UPDATES: list[dict[str, str]] = []

_loop: asyncio.AbstractEventLoop | None = None
_loop_lock = threading.Lock()


def path_of(ref: str) -> Path:
    """`source/name` → registry/sources/<source>/practices/<name>.py; `chains/name` → registry/chains/<name>.py."""
    head, _, name = ref.partition("/")
    if not name:
        raise ValueError(f"practice reference is 'source/name', got {ref!r}")
    if head == "chains":
        return REGISTRY / "chains" / f"{name}.py"
    return REGISTRY / "sources" / head / "practices" / f"{name}.py"


def load(ref: str):
    path = path_of(ref)
    if not path.exists():
        raise FileNotFoundError(f"no practice {ref} ({path})")
    spec = importlib.util.spec_from_file_location("practice_" + ref.replace("/", "__").replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, "run", None)):
        raise AttributeError(f"practice {ref} has no run()")
    return module


def _background_loop() -> asyncio.AbstractEventLoop:
    """One event loop on its own thread, so an async practice can be called from plain code."""
    global _loop
    with _loop_lock:
        if _loop is None:
            _loop = asyncio.new_event_loop()
            threading.Thread(target=_loop.run_forever, daemon=True, name="practices-loop").start()
        return _loop


def call(fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    """Calls a practice's run(), sync or async, and always returns its value."""
    result = fn(*args, **kwargs)
    if inspect.isawaitable(result):
        return asyncio.run_coroutine_threadsafe(_await(result), _background_loop()).result()
    return result


async def _await(awaitable):
    return await awaitable


def use(ref: str) -> Callable[..., Any]:
    """Another practice as a function. Each call is recorded as a step of the run."""
    module = load(ref)

    def step(*args: Any, **kwargs: Any) -> Any:
        started = time.perf_counter()
        entry: dict[str, Any] = {"ref": ref}
        try:
            value = call(module.run, *args, **kwargs)
        except BaseException as exc:
            entry.update(ok=False, ms=_ms(started), error=f"{type(exc).__name__}: {exc}")
            STEPS.append(entry)
            raise
        entry.update(ok=True, ms=_ms(started), **_shape.summary(value, preview_rows=50))
        entry["input"] = _shape.brief({"args": list(args), "kwargs": kwargs})
        STEPS.append(entry)
        return value

    step.__name__ = ref.rsplit("/", 1)[-1].replace("-", "_")
    step.__doc__ = module.run.__doc__
    return step


def update_secret(key: str, value: str) -> None:
    """Hands a new value of one of the source's keys (a rotated token) back to the store."""
    SECRET_UPDATES.append({"key": key, "value": value})
    os.environ[key] = value


def _ms(started: float) -> int:
    return int((time.perf_counter() - started) * 1000)
