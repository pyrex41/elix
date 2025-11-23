# syntax = docker/dockerfile:1

ARG ELIXIR_VERSION=1.15.7
ARG ERLANG_VERSION=26.2.5
ARG DEBIAN_VERSION=bookworm-20240701-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod LANG=C.UTF-8

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod && \
    mix deps.compile

COPY lib lib
COPY priv priv

RUN mix compile && \
    mix release

FROM debian:${DEBIAN_VERSION} AS app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends openssl libstdc++6 libsqlite3-0 ca-certificates ffmpeg && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
WORKDIR /app

COPY --from=build /app/_build/prod/rel/backend ./

CMD ["bin/backend", "start"]
