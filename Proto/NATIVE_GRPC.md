# Native gRPC path (optional, later)

The app's default Real mode uses the **grpcurl bridge** (`RealDishClient` shells
`grpcurl -plaintext -protoset Proto/dish.protoset`), so no Swift codegen is needed.

Go fully native only if you want zero external binaries:

1. `brew install protoc` + add Swift plugins:
   `protoc-gen-swift` (swift-protobuf) and `protoc-gen-grpc-swift` (grpc-swift v2).
2. Get current `.proto` sources. The vendored `dish.protoset` is a compiled
   `FileDescriptorSet` — decode it to `.proto` with e.g. `buf` / `protoreflect`,
   or pull fresh sources from the dish with grpc reflection, or from a community
   repo that vendors `.proto` text.
3. Generate with `protoc --descriptor_set_in=Proto/dish.protoset` (or from `.proto`
   sources) using `--swift_out` + `--grpc-swift_out`, add
   `grpc-swift` + `grpc-swift-nio-transport` + `grpc-swift-protobuf` to
   Package.swift (requires macOS 15+, swift-tools 6.0), and re-implement
   `RealDishClient` against `SpaceX_API_Device_DeviceAsyncClient.handle()`.
4. Field numbers that must match (verified vs starlink-grpc-go):
   Request: `get_status=1004`, `get_history=1007` (empty messages);
   Response: `dish_get_status=2004`, `dish_get_history=2006`;
   Status: snr=1001, drop=1003, obsStats=1004, alerts=1005, state=1006 (1=CONNECTED),
   down=1007, up=1008, latency=1009; wedges=2/3 (packed fixed32) in obstruction stats;
   history arrays: drop=1001, lat=1002, down=1003, up=1004, snr=1005 (packed fixed32).

Keep the grpcurl bridge as fallback — it tracks dish firmware without recompiling.
