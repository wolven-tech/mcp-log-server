# syntax=docker/dockerfile:1.7
# =============================================================================
# MCP Log Server - Multi-Stage Dockerfile
# =============================================================================

ARG ELIXIR_VERSION=1.17
ARG OTP_VERSION=27
ARG ALPINE_VERSION=3.23

# =============================================================================
# Stage 1: Build
# =============================================================================
FROM elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}-alpine AS builder

RUN apk add --no-cache git build-base

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only $MIX_ENV && \
    mix deps.compile

COPY lib lib

RUN mix compile && \
    mix release

# =============================================================================
# Stage 2: Runtime
# =============================================================================
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
    libstdc++ \
    libgcc \
    ncurses-libs \
    openssl \
    tini && \
    rm -rf /var/cache/apk/* /tmp/* && \
    addgroup -g 1000 appuser && \
    adduser -u 1000 -G appuser -s /sbin/nologin -D appuser && \
    mkdir -p /tmp/mcp-logs && \
    chown appuser:appuser /tmp/mcp-logs

WORKDIR /app

COPY --from=builder --chown=appuser:appuser /app/_build/prod/rel/mcp_log_server ./

USER appuser:appuser

ENV MIX_ENV=prod \
    LOG_DIR=/tmp/mcp-logs

ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD ["bin/mcp_log_server", "start"]
