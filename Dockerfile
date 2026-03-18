# Stage 1: build
FROM haskell:9.6 AS build

WORKDIR /build

# Copy dependency metadata first for layer caching
COPY purermyha.cabal cabal.project ./

# Build only dependencies (cached unless .cabal or cabal.project changes)
RUN cabal update && cabal build --only-dependencies all

# Copy full source tree
COPY . .

# Build everything
RUN cabal build all

# Run tests
RUN cabal test

# Stage binaries to a known location
RUN mkdir -p /staging && \
    cp "$(cabal list-bin purermyhad)" /staging/purermyhad && \
    cp "$(cabal list-bin purermyha)"  /staging/purermyha

# Stage 2: runtime
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libgmp10 zlib1g && \
    rm -rf /var/lib/apt/lists/*

# Copy binaries
COPY --from=build /staging/purermyhad /usr/sbin/purermyhad
COPY --from=build /staging/purermyha  /usr/bin/purermyha

# Copy config example and systemd service
COPY config/config.yaml.example /etc/purermyha/config.yaml.example
COPY packaging/purermyhad.service /usr/lib/systemd/system/purermyhad.service

CMD ["purermyhad"]
