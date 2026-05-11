FROM swift:6.0-jammy AS builder

WORKDIR /app
COPY TidepoolShared/ ./TidepoolShared/
COPY TidepoolServer/ ./TidepoolServer/

WORKDIR /app/TidepoolServer
# --static-swift-stdlib makes the linker hold huge symbol tables in memory and
# blew Railway's build container past its 8GB limit. Dynamic linking keeps
# peak memory low; the runtime stage below ships the matching Swift dylibs.
RUN swift build -c release

FROM swift:6.0-jammy-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libcurl4 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/TidepoolServer/.build/release/App ./

EXPOSE 8080
ENTRYPOINT ["./App", "serve", "--env", "production", "--hostname", "0.0.0.0"]
