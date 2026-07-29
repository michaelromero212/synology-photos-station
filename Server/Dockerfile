# Multi-stage build for the FrameStation server.
#
# Build context is the REPOSITORY ROOT, not Server/ — the server depends on
# ../Packages/FrameStationAPI by path, so that sibling must be inside the
# context. Build with:
#
#   docker build -f Server/Dockerfile .
#
# docker-compose.yml already sets this up. Target platform is linux/amd64; the
# DS920+ is an Intel Celeron J4125. See README.md "Building the image" for why
# you probably do not want to run this build on the NAS itself.

# ==============================================================================
# Build
# ==============================================================================
FROM swift:6.0-jammy AS build

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Manifests first so dependency resolution caches independently of source edits.
COPY ./Packages/FrameStationAPI/Package.swift ./Packages/FrameStationAPI/
COPY ./Server/Package.swift ./Server/Package.resolved* ./Server/
WORKDIR /build/Server
RUN swift package resolve

WORKDIR /build
COPY ./Packages ./Packages
COPY ./Server ./Server

WORKDIR /build/Server
RUN swift build -c release --product FrameStationServer -Xlinker -ljemalloc

WORKDIR /staging

RUN BIN_PATH="$(swift build --package-path /build/Server -c release --show-bin-path)" \
    && cp "$BIN_PATH/FrameStationServer" ./ \
    # The SQL migrations ship in a resource bundle that must sit beside the
    # binary. Losing this line is the classic "Migrations/SQL missing" failure.
    && find -L "$BIN_PATH/" -regex '.*\.resources$' -exec cp -Ra {} ./ \;

# ==============================================================================
# Run
# ==============================================================================
FROM swift:6.0-jammy-slim

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y ca-certificates tzdata libjemalloc2 \
    # Media pipeline. The server shells out to all three; without them the
    # derivation worker refuses to start and logs which are missing.
    #   libvips-tools  thumbnails and the ThumbHash source render
    #   libheif1       HEIC/HEIF decode — most of an iPhone library
    #   libexif / exiftool  EXIF, including lens and exposure
    #   ffmpeg         video probe and poster frames
    && apt-get -q install -y libvips-tools libheif1 libexif12 exiftool ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Fail the build rather than ship an image that cannot thumbnail an iPhone
# photo. Ubuntu's libvips is normally built against libheif, but "normally" is
# not something to discover in production at 2am.
RUN vips -l 2>/dev/null | grep -q heif \
    && echo "vips: HEIF support present" \
    || (echo "ERROR: vips has no HEIF loader; HEIC photos would fail" && exit 1)

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app

USER vapor:vapor
EXPOSE 8080

ENTRYPOINT ["./FrameStationServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
