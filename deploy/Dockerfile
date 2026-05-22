## ─── Stage 1: Build Frontend ────────────────────────────────────────────────
FROM node:20-slim AS frontend-builder
RUN npm install -g pnpm
WORKDIR /app/frontend
COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY frontend/ .
RUN pnpm build
# Output: /app/frontend/dist/

## ─── Stage 2: Build CLIPS ────────────────────────────────────────────────────
FROM debian:bookworm-slim AS clips-builder
RUN apt-get update && apt-get install -y gcc make curl && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl -sL "https://sourceforge.net/projects/clipsrules/files/CLIPS/6.40/clips_core_source_640.tar.gz/download" -o clips.tar.gz \
    && tar xzf clips.tar.gz \
    && cd clips_core_source_640/core \
    && cc -c -O2 -DGENERIC *.c \
    && ar rcs libclips.a *.o

## ─── Stage 3: Build Erlang Release ──────────────────────────────────────────
FROM erlang:26-slim AS erlang-builder
RUN apt-get update && apt-get install -y gcc make git && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Fetch Erlang deps first — cached as long as rebar.config/rebar.lock unchanged
COPY rebar.config rebar.lock* ./
RUN rebar3 get-deps

# CLIPS library
COPY --from=clips-builder /build/clips_core_source_640/core/*.h c_src/clips_lib/
COPY --from=clips-builder /build/clips_core_source_640/core/libclips.a c_src/clips_lib/

# Frontend dist injected into priv/static/ before release packaging
COPY --from=frontend-builder /app/frontend/dist/ priv/static/

# Erlang sources
COPY src/ src/
COPY config/ config/
COPY priv/ priv/
COPY c_src/ersub_clips.c c_src/Makefile c_src/

RUN cd c_src && make
RUN rebar3 as prod release

## ─── Stage 4: Runtime ────────────────────────────────────────────────────────
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y openssl libncurses6 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=erlang-builder /app/_build/prod/rel/ersub/ .
COPY config/ersub.yaml config/
COPY deploy/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

RUN groupadd -r ersub && useradd -r -g ersub -d /app -s /sbin/nologin ersub \
    && chown -R ersub:ersub /app
USER ersub

ENV DB_HOST=postgres
ENV DB_PORT=5432
ENV DB_USER=postgres

EXPOSE 8080
VOLUME ["/app/data"]
ENTRYPOINT ["/app/entrypoint.sh"]
