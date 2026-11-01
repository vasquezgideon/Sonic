#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/Combine.swift" <<'SWIFT'
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
SWIFT
swiftc -emit-module -module-name Combine "$TMP/Combine.swift" -emit-module-path "$TMP/Combine.swiftmodule"

cat > "$TMP/CryptoKit.swift" <<'SWIFT'
import Foundation
public enum Insecure {
    public enum MD5 {
        public static func hash(data: Data) -> [UInt8] { Array(repeating: 0, count: 16) }
    }
}
SWIFT
swiftc -emit-module -module-name CryptoKit "$TMP/CryptoKit.swift" -emit-module-path "$TMP/CryptoKit.swiftmodule"

cat > "$TMP/PlatformStubs.swift" <<'SWIFT'
import Foundation
enum KeychainStore {
    static func get(_ key: String) -> String? { nil }
    static func set(_ value: String, for key: String) throws {}
}
#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { true }
    func stopAccessingSecurityScopedResource() {}
}
#endif
SWIFT

swiftc -typecheck -I "$TMP" \
  "$TMP/PlatformStubs.swift" \
  Sonic/Models/Track.swift \
  Sonic/Services/LibraryStore.swift \
  Sonic/Services/CatalogService.swift \
  Sonic/Services/ServerService.swift

echo "Portable data, catalog, library and server services typecheck: OK"

swiftc \
  "$TMP/PlatformStubs.swift" \
  Sonic/Models/Track.swift \
  Sonic/Services/CatalogService.swift \
  scripts/ModelSmoke.swift \
  -o "$TMP/model-smoke"
"$TMP/model-smoke"
