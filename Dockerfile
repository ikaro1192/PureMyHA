# Stage 1: build
FROM haskell:9.6 AS build

WORKDIR /build

# Copy dependency metadata first for layer caching
COPY puremyha.cabal cabal.project ./

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
    cp "$(cabal list-bin puremyhad)" /staging/puremyhad && \
    cp "$(cabal list-bin puremyha)"  /staging/puremyha

# Stage 2: runtime
FROM ghcr.io/debian/debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libgmp10 zlib1g && \
    rm -rf /var/lib/apt/lists/*

# Copy binaries
COPY --from=build /staging/puremyhad /usr/sbin/puremyhad
COPY --from=build /staging/puremyha  /usr/bin/puremyha

# Copy config example and systemd service
COPY config/config.yaml.example /etc/puremyha/config.yaml.example
COPY packaging/puremyhad.service /usr/lib/systemd/system/puremyhad.service

CMD ["puremyhad"]
