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


def apply_validation(field_schema, raw_type, validation):
    if "anyOf" in field_schema:
        field_schema["anyOf"][0] = apply_validation(field_schema["anyOf"][0], raw_type.rstrip("?"), validation)
        return field_schema
    text = validation.strip()
    schema_type = field_schema.get("type")
    numbers = re.search(r"(\d+)\s*\.\.\s*(\d+)", text)
    if numbers:
        low, high = map(int, numbers.groups())
        if schema_type == "string":
            if "bytes" in text:
                field_schema["x-minUtf8Bytes"] = low
                field_schema["x-maxUtf8Bytes"] = high
            elif "caracter" in text or "Unicode" in text:
                field_schema["minLength"] = low
                field_schema["maxLength"] = high
        elif schema_type == "integer":
            field_schema["minimum"] = low
            field_schema["maximum"] = high
        elif schema_type == "array":
            field_schema["minItems"] = low
            field_schema["maxItems"] = high
    elif schema_type == "integer":
        minimum = re.search(r">=\s*(\d+)", text)
        if minimum:
            field_schema["minimum"] = int(minimum.group(1))
        exact = re.search(r"exatamente\s+(\d+)", text, re.IGNORECASE)
        if exact:
            field_schema["const"] = int(exact.group(1))
    elif schema_type == "string":
        byte_max = re.search(r"(?:<=|até|máximo)\s*(\d+)\s*bytes", text, re.IGNORECASE)
        if byte_max:
            field_schema["x-maxUtf8Bytes"] = int(byte_max.group(1))
        if "base64url" in text.lower():
            if "32 bytes" in text.lower():
                field_schema["x-format"] = "base64url32"
            else:
                field_schema["pattern"] = "^[A-Za-z0-9_-]+$"
        elif "base64" in text.lower():
            field_schema["x-format"] = "base64"
        if "40 hex" in text:
            field_schema["pattern"] = "^[a-f0-9]{40}$"
        if "owner/repo" in text.lower():
            field_schema["minLength"] = 3
            field_schema["pattern"] = r"^[^/\s]+/[^/\s]+$"
        if "basename sem path" in text.lower():
            field_schema["x-format"] = "basename"
        if "root-relative" in text.lower() or "sem escape" in text.lower():
            field_schema["x-format"] = "relative-path"
        if "url https" in text.lower():
            field_schema["x-format"] = "pairing-endpoint"
        if "git check-ref-format" in text.lower() and "prefixo codex/" in text.lower():
            field_schema["x-format"] = "git-branch"
        decoded_limit = re.search(r"decodificad[oa]s?\s*(?:<=|até)\s*(\d+)\s*KiB", text, re.IGNORECASE)
        if decoded_limit:
            field_schema["x-maxBase64DecodedBytes"] = int(decoded_limit.group(1)) * 1024
    elif schema_type == "array":
        maximum = re.search(r"(?:<=|até)\s*(\d+)", text, re.IGNORECASE)
        if maximum:
            field_schema["maxItems"] = int(maximum.group(1))
        if "únic" in text.lower():
            field_schema["uniqueItems"] = True
    if schema_type == "array" and "únic" in text.lower():
        field_schema["uniqueItems"] = True
    if "hostname" in text.lower():
        field_schema["x-format"] = "hostname"
    if "sha-256" in text.lower() or "SHA-256" in text:
        field_schema["x-format"] = "sha256"
    if schema_type == "string":
        if "base64url" in text.lower() and "32 bytes" in text.lower():
            field_schema["x-format"] = "base64url32"
        elif "base64" in text.lower():
            field_schema["x-format"] = "base64"
        if "basename sem path" in text.lower():
            field_schema["x-format"] = "basename"
        if "root-relative" in text.lower() or "sem escape" in text.lower():
            field_schema["x-format"] = "relative-path"
        if "url https" in text.lower():
            field_schema["x-format"] = "pairing-endpoint"
        if "git check-ref-format" in text.lower() and "prefixo codex/" in text.lower():
            field_schema["x-format"] = "git-branch"
        decoded_limit = re.search(r"decodificad[oa]s?\s*(?:<=|até)\s*(\d+)\s*KiB", text, re.IGNORECASE)
        if decoded_limit:
            field_schema["x-maxBase64DecodedBytes"] = int(decoded_limit.group(1)) * 1024
    return field_schema


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


def permission_action_schema():
    uuid = {"$ref": "#/$defs/uuid"}
    string = lambda limit: {"type": "string", "x-maxUtf8Bytes": limit}
    array = lambda item, minimum=0, maximum=100: {"type": "array", "items": item, "minItems": minimum, "maxItems": maximum}
    variants = [
        object_schema([
            ("kind", {"const": "command"}, True), ("workspace_id", uuid, True),
            ("cwd_relative", string(4096), True), ("argv", array(string(4096), 1, 64), True),
        ]),
        object_schema([
            ("kind", {"const": "edit"}, True), ("workspace_id", uuid, True),
            ("edits", array({"$ref": "#/$defs/EditPreview"}, 1, 100), True),
        ]),
        object_schema([
            ("kind", {"const": "question"}, True), ("question", string(4096), True),
            ("options", array({"$ref": "#/$defs/QuestionOption"}, 0, 10), True),
        ]),
        object_schema([
            ("kind", {"const": "forge"}, True), ("forge", {"$ref": "#/$defs/ForgePreview"}, True),
        ]),
    ]
    return {"oneOf": variants, "discriminator": {"propertyName": "kind"}}


def forge_preview_schema():
    base = {
        "host": {"type": "string", "minLength": 1, "maxLength": 253, "x-format": "hostname"},
        "repository": {"type": "string", "minLength": 3, "maxLength": 512, "pattern": r"^[^/\s]+/[^/\s]+$"},
        "head_sha": {"type": "string", "pattern": r"^[a-f0-9]{40}$"},
        "body": {"type": "string", "x-maxUtf8Bytes": 16384},
    }
    def variant(operation, required, optional=None, body_rule=None):
        properties = dict(base)
        properties["operation"] = {"const": operation}
        properties.update(optional or {})
        if body_rule is not None:
            properties["body"] = body_rule
        return {"type": "object", "additionalProperties": False, "required": ["host", "repository", "operation", "head_sha", "body", *required], "properties": properties}
    branch = {"type": "string", "x-minUtf8Bytes": 1, "x-maxUtf8Bytes": 120}
    pr_number = {"type": "integer", "minimum": 1}
    no_body = {"type": "string", "x-maxUtf8Bytes": 16384}
    body = {"type": "string", "minLength": 1, "x-maxUtf8Bytes": 16384}
    return {"oneOf": [
        variant("link", ["pr_number"], {"pr_number": pr_number}, no_body),
        variant("create_draft", ["title", "base_branch", "head_branch"], {
            "title": {"type": "string", "x-minUtf8Bytes": 1, "x-maxUtf8Bytes": 256},
            "base_branch": branch, "head_branch": branch,
        }, body),
        variant("comment", ["pr_number"], {"pr_number": pr_number}, body),
        variant("review", ["pr_number", "review_event"], {
            "pr_number": pr_number, "review_event": {"const": "approve"},
        }, no_body),
        variant("review", ["pr_number", "review_event"], {
            "pr_number": pr_number, "review_event": {"enum": ["comment", "request_changes"]},
        }, body),
        variant("merge", ["pr_number", "merge_method"], {
            "pr_number": pr_number,
            "merge_method": {"type": "string", "enum": ["merge", "squash", "rebase"]},
        }, no_body),
    ], "discriminator": {"propertyName": "operation"}}


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
                    if validation:
                        field_schema = apply_validation(field_schema, field_type, validation.group(1))
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
    definitions["PermissionAction"] = permission_action_schema()
    definitions["ForgePreview"] = forge_preview_schema()
    definitions["localCredentialMetadata"] = {
        "type": "object",
        "additionalProperties": False,
        "required": ["principal_id", "environment_id", "scopes", "audience", "expires_at_ms"],
        "properties": {
            "principal_id": {"$ref": "#/$defs/uuid"},
            "environment_id": {"$ref": "#/$defs/uuid"},
            "thread_id": {"$ref": "#/$defs/uuid"},
            "scopes": {"type": "array", "uniqueItems": True, "items": {"$ref": "#/$defs/scope"}},
            "audience": {"type": "string", "minLength": 1},
            "expires_at_ms": {"type": "integer", "minimum": 0},
        },
    }
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
        "runtime.dispatch input command_id and expected_revision must equal the envelope fields, per R1."
    )
    SCHEMA_PATH.write_text(json.dumps(schema, ensure_ascii=False, indent=2) + "\n")
    print(f"generated {len(seen)} entity schemas and {len(feature_snapshots)} snapshot schemas")


if __name__ == "__main__":
    raise SystemExit(main())
