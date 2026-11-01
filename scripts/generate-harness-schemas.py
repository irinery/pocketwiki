#!/usr/bin/env python3
"""Generate closed entity and FeatureSnapshot schemas from RFC YAML blocks."""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RFC_DIR = ROOT / "docs/rfcs/new-harness"
SCHEMA_PATH = ROOT / "src/harness/contracts/harness-v1.schema.json"

MODULE_EVENT_TYPES = {
    "runtime": ["RuntimeReceipt", "EffectRecord", "RuntimeEvent"],
    "providers": ["ProviderBinding", "ProviderCapabilities"],
    "threads": ["ThreadState", "ConversationMessage", "QueueEntry", "RunRecord", "TimelineItem"],
    "composer": ["ComposerDraft"],
    "permissions": ["PermissionRequest"],
    "workspaces": ["ProjectRecord", "WorkspaceLease", "WorkspaceSettings"],
    "checkpoints": ["Checkpoint"],
    "terminal": ["TerminalState", "TerminalFrame"],
    "environments": ["EnvironmentConnection"],
    "orchestrator-mcp": ["MCPThreadSummary"],
    "handoffs": ["ThreadLineage"],
    "memory": ["MemoryNote"],
    "source-control": ["PullRequestLink", "ForgeAction"],
    "navigation": ["NavigationEntry", "InboxNotification"],
    "diagnostics": ["ComponentHealth"],
}


def parse_type(raw):
    value = raw.strip().strip('"').strip("'")
    if value.endswith("?"):
        return {"anyOf": [parse_type(value[:-1]), {"type": "null"}]}
    if value.startswith("array[") and value.endswith("]"):
        return {"type": "array", "items": parse_type(value[6:-1]), "maxItems": 100}
    if value.startswith("enum[") and value.endswith("]"):
        return {"type": "string", "enum": value[5:-1].split(",")}
    primitives = {
        "uuid": {"$ref": "#/$defs/uuid"},
        "sha256": {"$ref": "#/$defs/sha256"},
        "sha1": {"type": "string", "pattern": "^[a-f0-9]{40}$"},
        "string": {"type": "string", "x-maxUtf8Bytes": 4096},
        "bool": {"type": "boolean"},
        "int": {"type": "integer"},
    }
    if value in primitives:
        return dict(primitives[value])
    if re.fullmatch(r"[A-Z][A-Za-z0-9]+", value):
        return {"$ref": f"#/$defs/{value}"}
    raise ValueError(f"unsupported RFC field type: {raw}")


def field_blocks(markdown):
    for block in re.findall(r"```yaml\s*\n(.*?)\n```", markdown, re.S):
        name_match = re.match(r"tipo: ([^\n]+)\ncampos:\n", block)
        if not name_match:
            continue
        name = name_match.group(1).strip().strip('"')
        fields = []
        matches = list(re.finditer(r"^  - nome: ([^\n]+)\n    tipo: ([^\n]+)(.*?)(?=\n  - nome: |\Z)", block, re.M | re.S))
        for match in matches:
            field_name = match.group(1).strip().strip('`"')
            raw_type = match.group(2).strip()
            rest = match.group(3)
            required_match = re.search(r"^    obrigatório: (true|false)$", rest, re.M)
            limit_match = re.search(r"^    limite: (.+)$", rest, re.M)
            field_schema = parse_type(raw_type)
            if limit_match and field_schema.get("type") == "string":
                limit = limit_match.group(1).strip().strip('"')
                byte_match = re.search(r"(?:0\.\.)?(\d+)\s*bytes", limit)
                mib_match = re.search(r"(?:0\.\.)?(\d+(?:\.\d+)?)\s*MiB", limit)
                if mib_match:
                    field_schema["x-maxUtf8Bytes"] = int(float(mib_match.group(1)) * 1024 * 1024)
                elif byte_match:
                    field_schema["x-maxUtf8Bytes"] = int(byte_match.group(1))
            fields.append((field_name, field_schema, bool(required_match and required_match.group(1) == "true")))
        yield name, fields


def object_schema(fields):
    return {
        "type": "object",
        "additionalProperties": False,
        "required": [name for name, _, required in fields if required],
        "properties": {name: field_schema for name, field_schema, _ in fields},
    }


def operation_inputs():
    registry_path = ROOT / "src/harness/contracts/operation-registry.json"
    registry = json.loads(registry_path.read_text())
    result = {}
    for feature in json.loads((RFC_DIR / "manifest.json").read_text())["features"]:
        rfc = RFC_DIR / feature["path"]
        phase_one = rfc.read_text().split("## 3.2")[0]
        for block in re.findall(r"```yaml\s*\ninterface:\n(.*?)\n```", phase_one, re.S):
            name_match = re.search(r'^  nome: "([a-z][a-z0-9_.]+)"$', block, re.M)
            if not name_match:
                continue
            name = name_match.group(1)
            input_match = re.search(r"^  entrada:\n(.*?)(?=^  saída:)", block, re.M | re.S)
            fields = []
            if input_match:
                for match in re.finditer(r"^    - campo: ([^\n]+)\n      tipo: ([^\n]+)(.*?)(?=\n    - campo: |\Z)", input_match.group(1), re.M | re.S):
                    field_name = match.group(1).strip().strip('`"')
                    field_type = match.group(2).strip()
                    rest = match.group(3)
                    required_match = re.search(r"^      obrigatório: (true|false)$", rest, re.M)
                    field_schema = parse_type(field_type)
                    validation = re.search(r'^      validação: "(.*?)"$', rest, re.M)
                    if validation and field_schema.get("type") == "string":
                        byte_match = re.search(r"(?:0\.\.)?(\d+)\s*bytes", validation.group(1))
                        if byte_match:
                            field_schema["x-maxUtf8Bytes"] = int(byte_match.group(1))
                    fields.append((field_name, field_schema, bool(required_match and required_match.group(1) == "true")))
            result[name] = object_schema(fields)
    return registry, result


def main():
    schema = json.loads(SCHEMA_PATH.read_text())
    definitions = schema["$defs"]
    registry, input_schemas = operation_inputs()
    feature_snapshots = {}
    seen = {}
    errors = []
    manifest = json.loads((RFC_DIR / "manifest.json").read_text())
    module_by_path = {feature["path"]: feature["module"] for feature in manifest["features"]}

    for rfc in sorted(RFC_DIR.glob("[0-9][0-9][0-9][0-9]-*.md")):
        module = module_by_path.get(rfc.name)
        if not module:
            continue
        markdown = rfc.read_text()
        for name, fields in field_blocks(markdown):
            if name == "FeatureSnapshot":
                snapshot_name = f"{module}FeatureSnapshot"
                schema_type = object_schema(fields)
                old = feature_snapshots.get(snapshot_name)
                if old and old != schema_type:
                    errors.append(f"conflicting {snapshot_name} in {rfc.name}")
                feature_snapshots[snapshot_name] = schema_type
                continue
            schema_type = object_schema(fields)
            old = seen.get(name)
            if old and old != schema_type:
                errors.append(f"conflicting {name} in {rfc.name}")
            seen[name] = schema_type

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    definitions.update(seen)
    definitions.update(feature_snapshots)
    definitions.update({
        operation["input_schema"]: input_schemas[operation["name"]]
        for operation in registry["operations"]
    })
    definitions["HarnessError"] = {"$ref": "#/$defs/harnessError"}
    definitions["FeatureSnapshot"] = {
        "oneOf": [{"$ref": f"#/$defs/{name}"} for name in feature_snapshots]
    }
    schema["$defs"]["command"]["properties"]["operation"]["enum"] = [operation["name"] for operation in registry["operations"] if operation["class"] == "mutation"]
    schema["$defs"]["command"]["oneOf"] = [
        {
            "type": "object",
            "required": ["operation", "input"],
            "properties": {
                "operation": {"const": operation["name"]},
                "input": {"$ref": f"#/$defs/{operation['input_schema']}"},
            },
        }
        for operation in registry["operations"]
        if operation["class"] == "mutation" and operation["contract_status"] == "closed"
    ]
    schema["$defs"]["command"]["x-contractBlockedOperations"] = [
        operation["name"] for operation in registry["operations"] if operation["contract_status"] == "blocked"
    ]
    schema["$defs"]["snapshotEnvelope"]["properties"]["data"] = {"type": "object"}
    schema["$defs"]["snapshotEnvelope"]["oneOf"] = [
        {
            "type": "object",
            "additionalProperties": False,
            "required": ["module", "data"],
            "properties": {
                "module": {"const": module.removesuffix("FeatureSnapshot")},
                "data": {"$ref": f"#/$defs/{module}"},
            },
        }
        for module in feature_snapshots
    ]

    for module, entity_types in MODULE_EVENT_TYPES.items():
        event_variants = []
        for entity_type in entity_types:
            if entity_type not in seen:
                errors.append(f"missing entity schema {entity_type} for module {module}")
                continue
            event_variants.extend([
                {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["entity_type", "entity_key", "change", "value"],
                    "properties": {
                        "entity_type": {"const": entity_type},
                        "entity_key": {"type": "string", "x-maxUtf8Bytes": 1024, "x-format": "jcs"},
                        "change": {"const": "upsert"},
                        "value": {"$ref": f"#/$defs/{entity_type}"},
                    },
                },
                {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["entity_type", "entity_key", "change"],
                    "properties": {
                        "entity_type": {"const": entity_type},
                        "entity_key": {"type": "string", "x-maxUtf8Bytes": 1024, "x-format": "jcs"},
                        "change": {"const": "delete"},
                    },
                    "not": {"type": "object", "required": ["value"]},
                },
            ])
        definitions[f"{module}ModuleEvent"] = {"oneOf": event_variants}

    stream = definitions["streamEnvelope"]
    stream["properties"]["payload"] = {"type": "object"}
    stream["oneOf"] = []
    for module in MODULE_EVENT_TYPES:
        for delivery in ("inline", "reference"):
            props = {
                "protocol_major": {"const": 1},
                "event_id": {"$ref": "#/$defs/uuid"},
                "environment_id": {"$ref": "#/$defs/uuid"},
                "thread_id": {"$ref": "#/$defs/uuid"},
                "seq": {"type": "integer", "minimum": 0},
                "committed_at_ms": {"type": "integer", "minimum": 0},
                "module": {"const": module},
                "delivery": {"const": delivery},
            }
            required = ["protocol_major", "event_id", "environment_id", "seq", "committed_at_ms", "module", "delivery"]
            if delivery == "inline":
                props["payload"] = {"$ref": f"#/$defs/{module}ModuleEvent"}
                required.append("payload")
                forbidden = "payload_ref"
            else:
                props["payload_ref"] = {"$ref": "#/$defs/uuid"}
                required.append("payload_ref")
                forbidden = "payload"
            stream["oneOf"].append({
                "type": "object",
                "additionalProperties": False,
                "required": required,
                "properties": props,
                "not": {"type": "object", "required": [forbidden]},
            })
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    schema["$comment"] = (
        "Entity, snapshot and operation input schemas generated from NH RFC-0002–0016 phase-01 YAML. "
        "RFC-0002 runtime.dispatch is excluded from HarnessCommand validation until its duplicated fields are resolved; see issue #21."
    )
    SCHEMA_PATH.write_text(json.dumps(schema, ensure_ascii=False, indent=2) + "\n")
    print(f"generated {len(seen)} entity schemas and {len(feature_snapshots)} snapshot schemas")


if __name__ == "__main__":
    raise SystemExit(main())
