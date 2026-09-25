"""How a result is shown: table, tree or text — and the schema of its fields."""
from __future__ import annotations

import base64
import datetime as dt
import decimal
import json
import uuid
from typing import Any

MAX_ROWS = 500
MAX_TREE_ITEMS = 2000


def jsonable(value: Any) -> Any:
    """JSON-safe copy: datetimes as ISO text, Decimal as number, bytes as base64."""
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (dt.datetime, dt.date, dt.time)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        return "base64:" + base64.b64encode(bytes(value)).decode()
    if isinstance(value, dict):
        return {str(k): jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [jsonable(v) for v in value]
    if hasattr(value, "to_dict") and hasattr(value, "columns"):   # pandas.DataFrame
        return jsonable(value.to_dict(orient="records"))
    if hasattr(value, "_asdict"):                                  # namedtuple, psycopg rows
        return jsonable(value._asdict())
    if hasattr(value, "__dict__"):
        return jsonable(vars(value))
    return repr(value)


def type_name(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "str"
    if isinstance(value, dict):
        return "dict"
    if isinstance(value, list):
        return "list"
    return type(value).__name__


def _records(value: Any) -> tuple[list[str], list[list[Any]], int] | None:
    """Table form when the value is rows: a list of dicts or of sequences, a DataFrame, or
    `{key: [dict rows]}` (XKDB's reply), which becomes rows with the key as first column."""
    if hasattr(value, "to_dict") and hasattr(value, "columns"):
        value = value.to_dict(orient="records")
    if isinstance(value, dict) and value and all(isinstance(v, list) and all(isinstance(r, dict) for r in v) for v in value.values()):
        rows = [{"_key": k, **r} for k, rs in value.items() for r in rs]
        return _records(rows)
    if isinstance(value, (list, tuple)) and value:
        if all(isinstance(r, dict) for r in value):
            columns: list[str] = []
            for r in value[:MAX_ROWS]:
                for k in r:
                    if k not in columns:
                        columns.append(str(k))
            rows = [[jsonable(r.get(c)) for c in columns] for r in value[:MAX_ROWS]]
            return columns, rows, len(value)
        if all(isinstance(r, (list, tuple)) for r in value):
            width = max(len(r) for r in value[:MAX_ROWS])
            columns = [f"c{i}" for i in range(width)]
            rows = [[jsonable(x) for x in r] for r in value[:MAX_ROWS]]
            return columns, rows, len(value)
    return None


def flatten_schema(value: Any, counts: dict[str, dict[str, int]], prefix: str = "", depth: int = 0) -> None:
    if isinstance(value, dict) and depth < 4:
        for k, v in value.items():
            path = f"{prefix}.{k}" if prefix else str(k)
            counts.setdefault(path, {})
            t = type_name(v)
            counts[path][t] = counts[path].get(t, 0) + 1
            flatten_schema(v, counts, path, depth + 1)


def schema(value: Any) -> list[dict[str, Any]]:
    """Field paths with types, from up to MAX_ROWS rows (or the dict itself). No values."""
    counts: dict[str, dict[str, int]] = {}
    if hasattr(value, "to_dict") and hasattr(value, "columns"):
        value = value.to_dict(orient="records")
    if isinstance(value, dict) and value and all(isinstance(v, list) for v in value.values()):
        value = [r for rs in value.values() for r in rs]
    if isinstance(value, (list, tuple)):
        sample = [r for r in value[:MAX_ROWS] if isinstance(r, dict)]
        for r in sample:
            flatten_schema(r, counts)
        seen = len(sample)
    else:
        flatten_schema(value, counts)
        seen = 1
    out = []
    for path, types in counts.items():
        present = sum(n for t, n in types.items() if t != "null")
        main = max((t for t in types if t != "null"), key=lambda t: types[t], default="null")
        out.append({"path": path, "type": main, "present": present, "seen": seen})
    return out


def summary(value: Any, preview_rows: int = MAX_ROWS) -> dict[str, Any]:
    """Everything the UI shows about a value: its shape, a bounded copy, rows and schema."""
    out: dict[str, Any] = {"schema": schema(value)}
    records = _records(value)
    if records:
        columns, rows, total = records
        out.update(shape="table", columns=columns, rows=rows[:preview_rows], total=total)
    elif isinstance(value, (dict, list, tuple)):
        tree = jsonable(value)
        out.update(shape="tree", tree=_bounded(tree), total=len(value))
    elif value is None:
        out.update(shape="none", total=0)
    else:
        text = value if isinstance(value, str) else json.dumps(jsonable(value), ensure_ascii=False)
        out.update(shape="text", text=text[:200_000], total=1)
    out["bytes"] = len(json.dumps(jsonable(value), ensure_ascii=False, default=str).encode())
    return out


def _bounded(tree: Any, budget: list[int] | None = None) -> Any:
    budget = budget if budget is not None else [MAX_TREE_ITEMS]
    if budget[0] <= 0:
        return "…"
    budget[0] -= 1
    if isinstance(tree, dict):
        return {k: _bounded(v, budget) for k, v in list(tree.items())[:200]}
    if isinstance(tree, list):
        return [_bounded(v, budget) for v in tree[:200]]
    return tree


def brief(value: Any) -> Any:
    """A short, JSON-safe look at a step's input."""
    text = json.dumps(jsonable(value), ensure_ascii=False)
    return text if len(text) <= 300 else text[:300] + "…"
