"""Runs one practice for Practices. Not for direct use.

    python -m practices_runner run <ref> <params.json> <out.json>
    python -m practices_runner signature <ref> <out.json>

The result goes to <out.json>; the practice's own prints stay on stdout/stderr.
"""
from __future__ import annotations

import datetime as dt
import inspect
import json
import sys
import time
import traceback
import typing

import practices
from practices import _shape


def coerce(text: Any, annotation: Any) -> Any:
    """Parameters arrive as text from a form; the practice's annotations decide their type."""
    if not isinstance(text, str) or annotation is inspect.Parameter.empty:
        return _json_or_text(text)
    origin = typing.get_origin(annotation) or annotation
    if origin is str:
        return text
    if origin is bool:
        return text.strip().lower() in ("1", "true", "yes", "да")
    if origin is int:
        return int(text)
    if origin is float:
        return float(text)
    if origin is dt.datetime:
        return dt.datetime.fromisoformat(text)
    if origin is dt.date:
        return dt.date.fromisoformat(text)
    return _json_or_text(text)


def _json_or_text(text: Any) -> Any:
    if not isinstance(text, str):
        return text
    try:
        return json.loads(text)
    except ValueError:
        return text


def signature(ref: str) -> dict:
    module = practices.load(ref)
    sig = inspect.signature(module.run)
    try:
        hints = typing.get_type_hints(module.run)
    except Exception:  # noqa: BLE001 — unresolvable annotations are shown as written
        hints = {}
    params = []
    for p in sig.parameters.values():
        if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            continue
        ann = hints.get(p.name, p.annotation)
        params.append({
            "name": p.name,
            "annotation": None if ann is inspect.Parameter.empty else getattr(ann, "__name__", str(ann)).replace("typing.", ""),
            "default": None if p.default is inspect.Parameter.empty else _default_text(p.default),
            "required": p.default is inspect.Parameter.empty,
        })
    doc = inspect.getdoc(module.run) or inspect.getdoc(module) or ""
    return {"params": params, "doc": doc, "async": inspect.iscoroutinefunction(module.run)}


def _default_text(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(_shape.jsonable(value), ensure_ascii=False)


def run(ref: str, params: dict) -> dict:
    started = time.perf_counter()
    try:
        module = practices.load(ref)
        sig = inspect.signature(module.run)
        try:
            hints = typing.get_type_hints(module.run)
        except Exception:  # noqa: BLE001
            hints = {}
        kwargs = {k: coerce(v, hints.get(k, sig.parameters[k].annotation if k in sig.parameters else inspect.Parameter.empty))
                  for k, v in params.items() if v is not None and v != ""}
        value = practices.call(module.run, **kwargs)
        out = {"ok": True, **_shape.summary(value)}
    except BaseException as exc:  # noqa: BLE001 — everything is reported, nothing escapes
        out = {"ok": False, "error": f"{type(exc).__name__}: {exc}", "traceback": traceback.format_exc()}
    out["ms"] = int((time.perf_counter() - started) * 1000)
    out["steps"] = practices.STEPS
    out["secrets"] = practices.SECRET_UPDATES
    return out


def main() -> None:
    mode, ref = sys.argv[1], sys.argv[2]
    if mode == "signature":
        target = sys.argv[3]
        try:
            result = {"ok": True, **signature(ref)}
        except BaseException as exc:  # noqa: BLE001
            result = {"ok": False, "error": f"{type(exc).__name__}: {exc}", "traceback": traceback.format_exc()}
    else:
        with open(sys.argv[3], encoding="utf-8") as f:
            params = json.load(f)
        target = sys.argv[4]
        result = run(ref, params)
    with open(target, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, default=str)


if __name__ == "__main__":
    main()
