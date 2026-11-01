#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

printf '\n[validate] Checking Info.plist\n'
plutil -lint Sonic/Info.plist

printf '\n[validate] Checking Xcode project syntax and references\n'
plutil -lint Sonic.xcodeproj/project.pbxproj
PBX_JSON="$(mktemp)"
trap 'rm -f "$PBX_JSON"' EXIT
plutil -convert json -o "$PBX_JSON" Sonic.xcodeproj/project.pbxproj
python3 - "$PBX_JSON" <<'PY'
import json, pathlib, sys
project = json.load(open(sys.argv[1]))
objects = project['objects']
missing = []
for object_id, item in objects.items():
    isa = item.get('isa')
    if isa == 'PBXFileReference' and item.get('sourceTree') == 'SOURCE_ROOT':
        path = pathlib.Path(item.get('path', ''))
        if not path.exists(): missing.append(f'{object_id}: {path}')
    if isa == 'PBXBuildFile' and item.get('fileRef') not in objects:
        missing.append(f'{object_id}: missing fileRef {item.get("fileRef")}')
    if isa == 'PBXGroup':
        for child in item.get('children', []):
            if child not in objects: missing.append(f'{object_id}: missing group child {child}')
    if isa == 'PBXNativeTarget':
        for phase in item.get('buildPhases', []):
            if phase not in objects: missing.append(f'{object_id}: missing build phase {phase}')
        if item.get('buildConfigurationList') not in objects:
            missing.append(f'{object_id}: missing build configuration list')
if missing:
    raise SystemExit('\n'.join(missing))
print('PBX object graph and source references: OK')
print('Targets:', ', '.join(x['name'] for x in objects.values() if x.get('isa') == 'PBXNativeTarget'))
PY

printf '\n[validate] Checking shared Xcode scheme\n'
python3 - <<'PY'
import xml.etree.ElementTree as ET
ET.parse('Sonic.xcodeproj/xcshareddata/xcschemes/Sonic.xcscheme')
print('Shared scheme XML: OK')
PY

printf '\n[validate] Parsing Swift sources\n'
while IFS= read -r file; do
  swiftc -frontend -parse "$file"
  echo "  OK $file"
done < <(find Sonic SonicTests -name '*.swift' -type f | sort)

printf '\n[validate] Type-checking portable data and service layers\n'
bash ./scripts/portable-typecheck.sh

printf '\n[validate] Type-checking and exercising the platform-neutral lyrics parser\n'
SMOKE_BINARY="$(mktemp)"
trap 'rm -f "$PBX_JSON" "$SMOKE_BINARY"' EXIT
swiftc Sonic/Services/LyricsService.swift scripts/LyricsParserSmoke.swift -o "$SMOKE_BINARY"
"$SMOKE_BINARY"

printf '\n[validate] All static checks passed\n' 
