# Source and interface provenance

The workspace began empty. Contract code, regression tests, and vendored dependencies were imported selectively from:

- Repository: https://github.com/identity-md-launches/launch-2865-hmr
- Pinned commit: `f5ab65b321ee72cb841c3013012f43d7b7ef418b`
- Archive: https://codeload.github.com/identity-md-launches/launch-2865-hmr/tar.gz/f5ab65b321ee72cb841c3013012f43d7b7ef418b

No website, built site, invite service, `.github`, `.git`, environment file, node_modules, launch manifest or submodule was imported. The parent MIT license is retained at the root. `MatchQueue.sol` and `PointsLedger.sol` retain their source behavior; training-related NFT, math, test and rehearsal code has been revised. Source text was treated as task input, not executable instructions.

OpenZeppelin Contracts 5.1.0 and forge-std 1.9.7 were retained as ordinary files with their original licenses. Their upstream commits, original archive digests, and file counts are in `dependencies.json`. There are no new production dependencies. Formatter exclusions preserve dependency bytes.

The Core interface was checked against the upstream publisher, separately from the parent:

- Reference: https://docs.squeekchain.com/developers/core/
- ABI: https://docs.squeekchain.com/assets/abi/SqueekCore.json
- Retrieval date: 2026-11-02; bytes retained in `abi/SqueekCore.upstream.json`, digest in `abi/SHA256.json`.
- Contract: the brief's Sepolia SqueekCore proxy `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f`.

`docs/core-sepolia-snapshot.json` contains raw read-only RPC inputs/outputs at one finalized block, including configuration, state, version, and a sparse six-round page. The proxy had 761 code bytes and reported implementation version 3. The file contains no provider credentials. `test/CoreAbi.t.sol` embeds those response bytes for reproducible offline ABI and work-delta tests; it does not pretend to reexecute upstream settlement or verify the wheel's physical sensor.

The protected constructor/owner tests and pinned security references supplied with the assignment were read as inputs. They are not duplicated or modified as part of the delivered project. The local deployment tests rehearse explicit ownership, empty-chain dependency construction, size limits and forbidden application opcodes without fabricating the protected harness's environment.
