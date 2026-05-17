ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.1
ARG DEBIAN_VERSION=bookworm-20250630

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update && \
    apt-get install -y build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./

RUN mix local.hex --force && \
    mix local.rebar --force

RUN mix deps.get --only prod

COPY config config
RUN mix deps.compile

COPY priv/references_bucketed.bin priv/references_bucketed.bin
COPY priv/bucket_offsets.bin priv/bucket_offsets.bin
COPY priv/references_ivf.bin priv/references_ivf.bin
COPY priv/ivf_offsets.bin priv/ivf_offsets.bin
COPY priv/ivf_centroids.bin priv/ivf_centroids.bin
COPY lib lib
COPY native native
COPY Makefile Makefile

RUN mix compile
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update && \
    apt-get install -y \
      libstdc++6 \
      openssl \
      ncurses-bin \
      locales \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

ENV HOME=/app
ENV MIX_ENV=prod
ENV ERL_FLAGS="+S 1:1"

COPY --from=builder /app/_build/prod/rel/rinha_2026 ./

EXPOSE 3000

CMD ["bin/rinha_2026", "start"]
