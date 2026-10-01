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

# The Swift toolchain, pinned to the patch release. Three other places name it,
# and CI fails the build when any of them disagree: .swift-version (what swiftly
# and cloud sessions install), the server-linux job's container in ci.yml, and
# the Swift in the Xcode the apps build with — the one that resolves
# Server/Package.resolved. A toolchain older than the lockfile doesn't
# fail on its own: it quietly resolves older dependencies instead, which is how
# this image shipped older TLS and certificate code than the lockfile named
# for as long as this line said 6.0.
ARG SWIFT_VERSION=6.4.0

# ==============================================================================
# Build
# ==============================================================================
FROM swift:${SWIFT_VERSION}-jammy AS build

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Manifests first so dependency resolution caches independently of source edits.
# The lockfile is required, not optional: without it every build would resolve
# whatever happened to be newest that day.
COPY ./Packages/FrameStationAPI/Package.swift ./Packages/FrameStationAPI/
COPY ./Server/Package.swift ./Server/Package.resolved ./Server/
WORKDIR /build/Server
# Exactly the pinned versions, or stop. Left to itself SwiftPM re-resolves when
# a pin doesn't fit the toolchain and carries on with whatever does.
RUN swift package resolve --force-resolved-versions

WORKDIR /build
# FrameStationAPI only — deliberately not all of ./Packages. FrameStationKit is
# Apple-only (Keychain, ImageIO) and the server never imports it, but copying the
# whole directory put it in this layer's hash, so every FrameStationKit edit
# invalidated the cache and bought a full release rebuild the server did not
# need. That is the difference between a ~16 minute image job and a ~30 second
# one on an app-only commit. If the server ever does gain a second local package
# dependency, add it as its own COPY line rather than widening this back out.
COPY ./Packages/FrameStationAPI ./Packages/FrameStationAPI
COPY ./Server ./Server

WORKDIR /build/Server
RUN swift build -c release --product FrameStationServer --force-resolved-versions \
        -Xlinker -ljemalloc

WORKDIR /staging

RUN BIN_PATH="$(swift build --package-path /build/Server -c release --show-bin-path)" \
    && cp "$BIN_PATH/FrameStationServer" ./ \
    # The SQL migrations ship in a resource bundle that must sit beside the
    # binary. SwiftPM named it `<target>.resources` until Swift 6.4, which calls
    # it `<target>.bundle`; take either. A pattern that matches nothing copies
    # nothing without complaint, and the server then dies at launch looking for
    # its migrations, so the last line refuses to build an image without them.
    && find -L "$BIN_PATH/" -maxdepth 1 \( -name '*.resources' -o -name '*.bundle' \) \
         -exec cp -Ra {} ./ \; \
    && ls -d FrameStationServer_FrameStationServer.* >/dev/null

# ==============================================================================
# Run
# ==============================================================================
FROM swift:${SWIFT_VERSION}-jammy-slim

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y --no-install-recommends ca-certificates tzdata libjemalloc2 \
    # Media pipeline. The server shells out to all three; without them the
    # derivation worker refuses to start and logs which are missing.
    #   libvips-tools  thumbnails and the ThumbHash source render
    #   libheif1       HEIC/HEIF decode — most of an iPhone library
    #   libexif / exiftool  EXIF, including lens and exposure
    #   ffmpeg         video probe and poster frames
    #
    # --no-install-recommends matters here more than anywhere else in the file.
    # ffmpeg and exiftool each recommend a long tail of extra codecs, docs and
    # Perl modules that nothing in this server calls; apt installs them by
    # default. The HEIF check below is what keeps this from being reckless — if
    # trimming ever costs vips its HEIC loader, the build fails rather than
    # shipping an image that can't thumbnail an iPhone photo.
    && apt-get -q install -y --no-install-recommends \
         libvips-tools libheif1 libexif12 exiftool ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Offline reverse-geocoding dataset, baked in so the container is
# self-contained — no volume to mount, no network at runtime, and the family's
# coordinates never leave the NAS. GeoNames cities1000, CC BY 4.0. Trimmed from
# 19 columns to the 5 the geocoder reads, ~30 MB of text down to ~6 MB.
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get -q update && apt-get -q install -y --no-install-recommends curl unzip \
    && mkdir -p /opt/geonames /tmp/gn \
    && curl -fsSL -o /tmp/gn/cities.zip https://download.geonames.org/export/dump/cities1000.zip \
    && curl -fsSL -o /tmp/gn/admin1.txt https://download.geonames.org/export/dump/admin1CodesASCII.txt \
    && unzip -qo /tmp/gn/cities.zip -d /tmp/gn \
    && awk -F'\t' 'NF>=11 && $5 != "" && $6 != "" { printf "%s\t%s\t%s\t%s\t%s\n", $3, $5, $6, $9, $11 }' \
         /tmp/gn/cities1000.txt > /opt/geonames/cities.tsv \
    && awk -F'\t' 'NF>=2 { printf "%s\t%s\n", $1, $2 }' /tmp/gn/admin1.txt > /opt/geonames/admin1.tsv \
    && printf 'GeoNames (https://www.geonames.org/) - CC BY 4.0\n' > /opt/geonames/ATTRIBUTION.txt \
    && rm -rf /tmp/gn \
    && apt-get -q purge -y unzip && apt-get -q autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && wc -l /opt/geonames/cities.tsv

# Fail the build rather than ship an image that cannot thumbnail an iPhone
# photo. Ubuntu's libvips is normally built against libheif, but "normally" is
# not something to discover in production at 2am.
RUN vips -l 2>/dev/null | grep -q heif \
    && echo "vips: HEIF support present" \
    || (echo "ERROR: vips has no HEIF loader; HEIC photos would fail" && exit 1)

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app

# The commit this image was built from, reported by /health as `revision`. CI
# passes it; a local `docker compose build` leaves it unknown. Declared this
# late so a new commit only changes this one tiny layer and never the cache of
# the build above it.
ARG FRAMESTATION_REVISION=unknown
ENV FRAMESTATION_REVISION=${FRAMESTATION_REVISION}

USER vapor:vapor
EXPOSE 8080

ENTRYPOINT ["./FrameStationServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
