# The image tags of the build stage must follow ../mise.toml (Erlang and Elixir versions).
FROM hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261104-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
RUN mix release

FROM debian:trixie-20261104-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 locales tzdata ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
WORKDIR /app
COPY --from=build --chown=nobody:root /src/_build/prod/rel/pinata ./
USER nobody
ENTRYPOINT ["/app/bin/pinata"]
CMD ["start"]
