# MCP SDK: pinned runtime source

Upstream: https://github.com/modelcontextprotocol/swift-sdk
Version: 0.12.1
Revision: `a0ae212ebf6eab5f754c3129608bc5557637e605`

This local Swift package retains all 47 upstream `Sources/MCP` Swift files and
the exact upstream LICENSE. It is committed with the application so the fix is
reproducible without editing generated checkouts or relying on an unpublished fork.
It is not a new independently supported SDK distribution.

## Local changes

- `Sources/MCP/Base/Value.swift` decodes every JSON string as `.string`.
  Upstream implicitly interprets data-URI-looking strings as `.data`, losing
  their original spelling during both request decoding and result type erasure.
  This breaks literal text reads, exact-byte windows, and textual create arguments.
- Explicit `Value.data` encoding and the explicit data-URL helper APIs are unchanged.
  Decoding an encoded `.data` value now yields its JSON string, not an inferred
  binary value. Typed image/audio content continues to use separate string data
  and MIME fields.
- `Package.swift` is derived from upstream `Package@swift-6.0.swift`, retaining
  its runtime target, platforms, dependency constraints and platform conditions.
  The upstream test target is omitted. Conformance executables, documentation
  plugins, upstream tests and development tooling are not vendored.
- `Sources/MCP/Base/Transports/NetworkTransport.swift` makes an existing strong
  outer Task capture explicit (`@MainActor [self]`), removing Swift 6.4's
  implicit-strong-capture warning without changing ownership. The nested weak
  capture is unchanged; the application never instantiates this network transport.

No other runtime source is changed. Application raw-stdio tests cover literal
create/read, exact bytes, nested string types/spelling, and explicit binary/image
output through the actual SDK.

## Provenance checks

SHA-256 of upstream `Sources/MCP/Base/Value.swift`:
`6a8399cb11db842faac9f549143058e24d15763705be65701ffba714111aabeb`

SHA-256 of patched `Sources/MCP/Base/Value.swift`:
`72d0aea30ac3fe027d79a0b1ccf706fd3ed1a88547d1bcdc0ce048c650a02f73`

SHA-256 of upstream `Sources/MCP/Base/Transports/NetworkTransport.swift`:
`b9191de0d3bba42437c1889605fd85f8a6dea5c14b4cc5939b4be0448d68335d`

SHA-256 of patched `Sources/MCP/Base/Transports/NetworkTransport.swift`:
`f058cb6342b4f65ff800cc56aadf68447d13fde2552bcf80e36d853f716a8242`

SHA-256 of unchanged upstream LICENSE:
`0382b0057770ca05e9c350a50aa3b1c1fea84da0bc81d723bf00b9aa841be58a`

To audit, compare all runtime files against the exact upstream revision; only the
documented Value.swift and NetworkTransport.swift patches and their modification
notices should differ. Remote dependency versions remain recorded in the root
Package.resolved. Two unchanged upstream files (`OAuthDiscovery.swift` and
`OAuthWWWAuthenticateParser.swift`) retain blank lines at EOF; Git's initial-import
whitespace check flags them. They remain byte-identical to upstream.

Preserve upstream licensing and source notices when redistributing the server.
Remove this local package when an audited official SDK version preserves JSON
string identity and passes these regressions; do not replace it with a build-time
patch script or silently update its source.
