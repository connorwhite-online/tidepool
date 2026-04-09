FROM swift:5.9-jammy AS builder

WORKDIR /app
COPY TidepoolShared/ ./TidepoolShared/
COPY TidepoolServer/ ./TidepoolServer/

WORKDIR /app/TidepoolServer
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:jammy

RUN apt-get update && apt-get install -y \
    libcurl4 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/TidepoolServer/.build/release/App ./

EXPOSE 8080
ENTRYPOINT ["./App", "serve", "--env", "production", "--hostname", "0.0.0.0"]
