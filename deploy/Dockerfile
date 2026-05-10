## Stage 1: Build CLIPS
FROM debian:bookworm-slim AS clips-builder
RUN apt-get update && apt-get install -y gcc make curl && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl -sL "https://sourceforge.net/projects/clipsrules/files/CLIPS/6.40/clips_core_source_640.tar.gz/download" -o clips.tar.gz \
    && tar xzf clips.tar.gz \
    && cd clips_core_source_640/core \
    && cc -c -O2 -DGENERIC *.c \
    && ar rcs libclips.a *.o

## Stage 2: Build Erlang release
FROM erlang:26-slim AS erlang-builder
RUN apt-get update && apt-get install -y gcc make git && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Copy CLIPS library
COPY --from=clips-builder /build/clips_core_source_640/core/*.h c_src/clips_lib/
COPY --from=clips-builder /build/clips_core_source_640/core/libclips.a c_src/clips_lib/

# Copy project files
COPY rebar.config rebar.lock* ./
COPY src/ src/
COPY config/ config/
COPY priv/ priv/
COPY c_src/ersub_clips.c c_src/Makefile c_src/

# Build CLIPS wrapper
RUN cd c_src && make

# Build Erlang release
RUN rebar3 as prod release

## Stage 3: Runtime
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y openssl libncurses6 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=erlang-builder /app/_build/prod/rel/ersub/ .
COPY --from=erlang-builder /app/priv/ priv/
COPY config/ersub.yaml config/

ENV DB_HOST=postgres
ENV DB_PORT=5432
ENV DB_USER=postgres
ENV DB_PASSWORD=changeme
ENV JWT_SECRET=changeme

EXPOSE 8080

CMD ["bin/ersub", "foreground"]
