# Builder image for the offline dsh Linux runtime.
# Base: official Node 24 Debian bookworm image (glibc 2.36 build baseline).
FROM node:24-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils unzip file procps iproute2 \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    npm_config_fund=false \
    npm_config_audit=false

WORKDIR /work
