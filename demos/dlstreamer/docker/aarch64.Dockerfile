# syntax=docker/dockerfile:1.7

###############################################################################
# TEAR DL Streamer AArch64 image — consolidated clean build
#
# Build from an x86-64 host using Docker Buildx/QEMU:
#
#   CLEAN=1 ./scripts/build-aarch64.sh
#
# Design:
#   * entire build runs inside Docker;
#   * no Conda or Micromamba;
#   * Ubuntu provides the compiler and build tools;
#   * OpenVINO archive is resolved from Intel's hierarchical filetree.json;
#   * DL Streamer's patched GStreamer is built locally;
#   * optional multimedia components unrelated to the CPU demo are disabled.
###############################################################################

FROM --platform=$TARGETPLATFORM ubuntu:24.04

ARG TARGETPLATFORM
ARG TARGETARCH

ARG OPENVINO_RELEASE=2026.1
ARG OPENVINO_VERSION_PREFIX=2026.1.0
ARG OPENVINO_STORAGE_ROOT=https://storage.openvinotoolkit.org

ENV DEBIAN_FRONTEND=noninteractive
ENV DLS_SOURCE=/src/dlstreamer
ENV DLS_BUILD=/src/dlstreamer/build-aarch64
ENV DLS_BUILD_LIB=/src/dlstreamer/build-aarch64/intel64/Release/lib
ENV OPENVINO_ROOT=/opt/intel/openvino
ENV OpenVINO_DIR=/opt/intel/openvino/runtime/cmake

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        binutils bison build-essential bzip2 ca-certificates cmake curl file \
        flex gettext git gzip libboost-dev libdw-dev libffi-dev libfmt-dev \
        libglib2.0-dev libjson-c-dev libmount-dev libopencv-dev libspdlog-dev \
        libssl-dev libunwind-dev libva-dev libx11-dev libxml2-dev \
        libxrandr-dev meson ninja-build nlohmann-json3-dev \
        ocl-icd-opencl-dev opencl-headers patch pkg-config python3 \
        python3-pip python3-setuptools python3-wheel rapidjson-dev tar \
        xz-utils zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# Ubuntu 24.04 ships Meson 1.3.x, but patched GStreamer requires Meson >= 1.4
###############################################################################

RUN python3 -m pip install \
        --break-system-packages \
        --no-cache-dir \
        "meson>=1.4,<2" && \
    test "$(command -v meson)" = "/usr/local/bin/meson" && \
    python3 -c 'import mesonbuild; print(mesonbuild.__file__)' && \
    meson --version | awk -F. '{ exit !(($1 > 1) || ($1 == 1 && $2 >= 4)) }'

###############################################################################
# Resolve and install the official OpenVINO AArch64 archive
###############################################################################

RUN <<'EOF'
set -euo pipefail

test "${TARGETARCH}" = "arm64"
test "$(uname -m)" = "aarch64"
mkdir -p "${OPENVINO_ROOT}"

curl \
    --fail \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 3 \
    "${OPENVINO_STORAGE_ROOT}/filetree.json" \
    --output /tmp/openvino-filetree.json

OPENVINO_ARCHIVE_PATH="$(
    python3 - \
        /tmp/openvino-filetree.json \
        "${OPENVINO_RELEASE}" \
        "${OPENVINO_VERSION_PREFIX}" <<'PY'
import json
import re
import sys
from typing import Any

filetree_path = sys.argv[1]
release = sys.argv[2]
version_prefix = sys.argv[3]

with open(filetree_path, "r", encoding="utf-8") as stream:
    tree: Any = json.load(stream)

# Intel's filetree is hierarchical: directory and filename components can be
# separate dictionary keys. Reconstruct full paths and retain leaf strings.
values: set[str] = set()


def add(value: str) -> None:
    normalized = value.replace("\\/", "/").strip()
    if normalized:
        values.add(normalized)


def walk(value: Any, parents: tuple[str, ...] = ()) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            key_text = str(key).replace("\\/", "/").strip("/")
            next_parents = parents + ((key_text,) if key_text else ())
            add(str(key))
            if next_parents:
                add("/".join(next_parents))
            walk(item, next_parents)
    elif isinstance(value, list):
        for item in value:
            walk(item, parents)
    elif isinstance(value, str):
        add(value)
        leaf = value.replace("\\/", "/").strip("/")
        if parents and leaf:
            add("/".join(parents + (leaf,)))


walk(tree)

filename_re = re.compile(
    r"openvino_toolkit_[^/]*" + re.escape(version_prefix) +
    r"[^/]*_arm64\.tgz$"
)

candidates: set[tuple[int, str]] = set()
available_arm64: set[str] = set()
marker = "repositories/openvino/packages/"

for raw in values:
    normalized = raw.split("?", 1)[0].strip("/")
    filename = normalized.rsplit("/", 1)[-1]

    if filename.startswith("openvino_toolkit_") and filename.endswith("_arm64.tgz"):
        available_arm64.add(filename)

    if not filename_re.fullmatch(filename):
        continue

    if "_ubuntu24_" in filename:
        priority = 0
    elif "_ubuntu22_" in filename:
        priority = 1
    elif "_ubuntu20_" in filename:
        priority = 2
    else:
        priority = 3

    marker_position = normalized.find(marker)
    if marker_position >= 0:
        archive_path = normalized[marker_position:]
    else:
        archive_path = (
            f"repositories/openvino/packages/{release}/linux/{filename}"
        )

    candidates.add((priority, archive_path))

if not candidates:
    print(
        "No matching OpenVINO archive found for "
        f"release={release}, version_prefix={version_prefix}",
        file=sys.stderr,
    )
    nearby = sorted(
        name for name in available_arm64
        if f"_{release}" in name or version_prefix.rsplit(".", 1)[0] in name
    )
    if nearby:
        print("Available nearby ARM64 archives:", file=sys.stderr)
        for name in nearby[:30]:
            print(f"  {name}", file=sys.stderr)
    sys.exit(1)

print(sorted(candidates)[0][1])
PY
)"

test -n "${OPENVINO_ARCHIVE_PATH}"

printf '[INFO] Resolved OpenVINO archive:\n'
printf '[INFO]   %s\n' "${OPENVINO_ARCHIVE_PATH}"

curl \
    --fail \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 3 \
    "${OPENVINO_STORAGE_ROOT}/${OPENVINO_ARCHIVE_PATH}" \
    --output /tmp/openvino.tgz

file /tmp/openvino.tgz
archive_size="$(stat -c '%s' /tmp/openvino.tgz)"

if [ "${archive_size}" -le 1000000 ]; then
    printf '[ERROR] OpenVINO archive is unexpectedly small: %s bytes\n' \
        "${archive_size}" >&2
    head -30 /tmp/openvino.tgz >&2 || true
    exit 1
fi

gzip -t /tmp/openvino.tgz

tar \
    -xzf /tmp/openvino.tgz \
    -C "${OPENVINO_ROOT}" \
    --strip-components=1

rm -f /tmp/openvino.tgz /tmp/openvino-filetree.json

test -f "${OPENVINO_ROOT}/setupvars.sh"
test -f "${OpenVINO_DIR}/OpenVINOConfig.cmake"
EOF

###############################################################################
# Build and runtime environment
###############################################################################

ENV GSTREAMER_ROOT="${DLS_BUILD}/deps/gstreamer-bin"
ENV PATH="${GSTREAMER_ROOT}/bin:${OPENVINO_ROOT}/tools/compile_tool:${PATH}"
ENV CMAKE_PREFIX_PATH="${GSTREAMER_ROOT}:${OPENVINO_ROOT}:/usr"
ENV PKG_CONFIG_PATH="${GSTREAMER_ROOT}/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
ENV LD_LIBRARY_PATH="${DLS_BUILD_LIB}:${GSTREAMER_ROOT}/lib:${OPENVINO_ROOT}/runtime/lib/aarch64:/usr/lib/aarch64-linux-gnu"
ENV GST_PLUGIN_SYSTEM_PATH_1_0=""
ENV GST_PLUGIN_PATH="${DLS_BUILD_LIB}:${GSTREAMER_ROOT}/lib/gstreamer-1.0"
ENV GST_PLUGIN_SCANNER=/opt/intel/dlstreamer/bin/gst-plugin-scanner
ENV GST_REGISTRY=/tmp/gst-registry-aarch64.bin

RUN test "$(uname -m)" = "aarch64" && \
    command -v python3 && \
    python3 -c 'import setuptools; print(setuptools.__version__)' && \
    bison --version && \
    flex --version && \
    cmake --version && \
    meson --version && \
    ninja --version && \
    pkg-config --version && \
    pkg-config --modversion glib-2.0 && \
    pkg-config --modversion opencv4 && \
    pkg-config --modversion libva && \
    test -f /usr/include/CL/cl.h && \
    test -f /usr/lib/aarch64-linux-gnu/libOpenCL.so && \
    test -f "${OpenVINO_DIR}/OpenVINOConfig.cmake"

WORKDIR /src
COPY third_party/dlstreamer "${DLS_SOURCE}"
WORKDIR "${DLS_SOURCE}"

RUN test -f CMakeLists.txt && \
    grep -aqF \
        "POWER_SAVE profile activated" \
        src/monolithic/gst/inference_elements/base/inference_impl.cpp && \
    grep -q \
        "GST_BASE_TRANSFORM_FLOW_DROPPED" \
        src/monolithic/gst/inference_elements/base/inference_impl.cpp

RUN <<'EOF'
set -euo pipefail

metadata_dir="${DLS_SOURCE}/include/dlstreamer/gst/metadata"

test -f "${DLS_SOURCE}/include/dlstreamer/gst/metadata.h"
test -d "${metadata_dir}"
test -f "${metadata_dir}/gva_tensor_meta.h"
test -f "${metadata_dir}/gva_json_meta.h"
test -f "${metadata_dir}/g3d_lidar_meta.h"

python3 - "${DLS_SOURCE}" "${metadata_dir}" <<'PY'
from pathlib import Path
import re
import sys

source_root = Path(sys.argv[1])
metadata_dir = Path(sys.argv[2])

source_suffixes = {
    ".c", ".cc", ".cpp", ".cxx",
    ".h", ".hh", ".hpp", ".hxx",
}

metadata_headers = {
    path.name
    for path in metadata_dir.iterdir()
    if path.is_file() and path.suffix in {".h", ".hpp"}
}

if not metadata_headers:
    raise SystemExit(f"No metadata headers found in {metadata_dir}")

# Match both quoted and angle-bracket includes, with or without
# the legacy metadata/ prefix.
include_re = re.compile(
    r'^(?P<prefix>\s*#\s*include\s*)'
    r'(?P<open>["<])'
    r'(?P<path>(?:metadata/)?(?P<name>[^"/<>]+))'
    r'(?P<close>[">])'
    r'(?P<suffix>\s*(?://.*)?)$'
)

changed_files = []

for path in source_root.rglob("*"):
    if not path.is_file() or path.suffix not in source_suffixes:
        continue

    original = path.read_text(
        encoding="utf-8",
        errors="surrogateescape",
    )
    output = []

    for line in original.splitlines(keepends=True):
        newline = ""
        content = line

        if line.endswith("\r\n"):
            content = line[:-2]
            newline = "\r\n"
        elif line.endswith("\n"):
            content = line[:-1]
            newline = "\n"

        match = include_re.match(content)

        if match and match.group("name") in metadata_headers:
            header = match.group("name")
            content = (
                f'{match.group("prefix")}'
                f'"dlstreamer/gst/metadata/{header}"'
                f'{match.group("suffix")}'
            )

        output.append(content + newline)

    updated = "".join(output)

    if updated != original:
        path.write_text(
            updated,
            encoding="utf-8",
            errors="surrogateescape",
        )
        changed_files.append(path.relative_to(source_root))

metadata_h_users = [
    source_root / "src/gst/elements/meta_smooth/meta_smooth.cpp",
]

for path in metadata_h_users:
    if not path.is_file():
        raise SystemExit(f"Expected source file is missing: {path}")

    original = path.read_text(encoding="utf-8")
    updated = re.sub(
        r'^(\s*#\s*include\s*)[<"]metadata\.h[>"]'
        r'(\s*(?://.*)?)$',
        r'\1"dlstreamer/gst/metadata.h"\2',
        original,
        flags=re.MULTILINE,
    )

    if updated != original:
        path.write_text(updated, encoding="utf-8")
        changed_files.append(path.relative_to(source_root))

print(f"Updated {len(changed_files)} source files:")
for path in changed_files:
    print(f"  {path}")

stale = []

for path in source_root.rglob("*"):
    if not path.is_file() or path.suffix not in source_suffixes:
        continue

    for line_number, line in enumerate(
        path.read_text(
            encoding="utf-8",
            errors="surrogateescape",
        ).splitlines(),
        start=1,
    ):
        match = include_re.match(line)

        if match and match.group("name") in metadata_headers:
            stale.append(
                f"{path.relative_to(source_root)}:"
                f"{line_number}: {line.strip()}"
            )

if stale:
    print("Legacy metadata includes remain:", file=sys.stderr)
    for item in stale:
        print(f"  {item}", file=sys.stderr)
    raise SystemExit(1)
PY

grep -q     '^#include "dlstreamer/gst/metadata/g3d_lidar_meta.h"$'     "${DLS_SOURCE}/src/monolithic/gst/elements/gvametaconvert/jsonconverter.cpp"

grep -q     '^#include "dlstreamer/gst/metadata/gva_json_meta.h"$'     "${DLS_SOURCE}/src/monolithic/gst/elements/gvametaconvert/jsonconverter.h"

grep -q     '^#include "dlstreamer/gst/metadata/gva_json_meta.h"$'     "${DLS_SOURCE}/src/monolithic/gst/elements/gvametapublish/base/gvametapublishbase.cpp"

grep -q     '^#include "dlstreamer/gst/metadata.h"$'     "${DLS_SOURCE}/src/gst/elements/meta_smooth/meta_smooth.cpp"
EOF

###############################################################################
# Parallel compilation
#
# The wrapper script passes the host-selected job count. Declaring the argument
# here limits cache invalidation from job-count changes to compilation layers.
###############################################################################

ARG BUILD_JOBS=1

RUN case "${BUILD_JOBS}" in \
        ''|*[!0-9]*|0) \
            printf '[ERROR] BUILD_JOBS must be a positive integer: %s\n' \
                "${BUILD_JOBS}" >&2; \
            exit 1 \
            ;; \
    esac

###############################################################################
# Minimise the patched GStreamer build
###############################################################################

RUN test -f dependencies/gstreamer.cmake && \
    sed -i \
        -e 's/-Dvaapi=enabled/-Dvaapi=disabled/g' \
        -e 's/-Dlibnice=enabled/-Dlibnice=disabled/g' \
        -e 's/-Dgst-plugins-base:xvideo=enabled/-Dgst-plugins-base:xvideo=disabled/g' \
        -e 's/-Dgst-plugins-base:vorbis=enabled/-Dgst-plugins-base:vorbis=disabled/g' \
        -e 's/-Dgst-plugins-good:vpx=enabled/-Dgst-plugins-good:vpx=disabled/g' \
        -e 's/-Dgst-plugins-good:soup=enabled/-Dgst-plugins-good:soup=disabled/g' \
        -e 's/-Dgst-plugins-bad:va=enabled/-Dgst-plugins-bad:va=disabled/g' \
        -e 's/-Dgst-plugins-bad:libde265=enabled/-Dgst-plugins-bad:libde265=disabled/g' \
        -e 's/-Dgst-plugins-bad:openh264=enabled/-Dgst-plugins-bad:openh264=disabled/g' \
        -e 's/-Dgst-plugins-bad:uvch264=enabled/-Dgst-plugins-bad:uvch264=disabled/g' \
        -e 's/-Dgst-plugins-bad:x265=enabled/-Dgst-plugins-bad:x265=disabled/g' \
        -e 's/-Dgst-plugins-bad:curl=enabled/-Dgst-plugins-bad:curl=disabled/g' \
        -e 's/-Dgst-plugins-bad:curl-ssh2=enabled/-Dgst-plugins-bad:curl-ssh2=disabled/g' \
        -e 's/-Dgst-plugins-bad:opus=enabled/-Dgst-plugins-bad:opus=disabled/g' \
        -e 's/-Dgst-plugins-bad:dtls=enabled/-Dgst-plugins-bad:dtls=disabled/g' \
        -e 's/-Dgst-plugins-bad:srtp=enabled/-Dgst-plugins-bad:srtp=disabled/g' \
        -e 's/-Dgst-plugins-bad:webrtc=enabled/-Dgst-plugins-bad:webrtc=disabled/g' \
        -e 's/-Dgst-plugins-ugly:x264=enabled/-Dgst-plugins-ugly:x264=disabled/g' \
        -e 's/-Dgstreamer-vaapi:encoders=enabled/-Dgstreamer-vaapi:encoders=disabled/g' \
        -e 's/-Dgstreamer-vaapi:drm=enabled/-Dgstreamer-vaapi:drm=disabled/g' \
        -e 's/-Dgstreamer-vaapi:glx=enabled/-Dgstreamer-vaapi:glx=disabled/g' \
        -e 's/-Dgstreamer-vaapi:wayland=enabled/-Dgstreamer-vaapi:wayland=disabled/g' \
        -e 's/-Dgstreamer-vaapi:egl=enabled/-Dgstreamer-vaapi:egl=disabled/g' \
        -e 's/--buildtype=release/--buildtype=release -Dintrospection=disabled -Dpython=disabled/' \
        dependencies/gstreamer.cmake && \
    ! grep -q -- '-Dgst-plugins-bad:uvch264=enabled' dependencies/gstreamer.cmake && \
    ! grep -q -- '-Dgst-plugins-bad:libde265=enabled' dependencies/gstreamer.cmake

RUN cmake \
        -S "${DLS_SOURCE}/dependencies" \
        -B "${DLS_BUILD}/deps" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DINSTALL_DLSTREAMER=OFF && \
    cmake --build "${DLS_BUILD}/deps" \
        --target gstreamer \
        --parallel "${BUILD_JOBS}"

RUN test -f \
        "${GSTREAMER_ROOT}/include/gstreamer-1.0/gst/analytics/gstanalyticskeypointmtd.h" && \
    test -f \
        "${GSTREAMER_ROOT}/include/gstreamer-1.0/gst/analytics/gstanalyticsgroupmtd.h" && \
    grep -q \
        "gst_analytics_mtd_set_semantic_tag" \
        "${GSTREAMER_ROOT}/include/gstreamer-1.0/gst/analytics/gstanalyticsmeta.h" && \
    test -f \
        "${GSTREAMER_ROOT}/lib/pkgconfig/gstreamer-analytics-1.0.pc"

###############################################################################
# Permanently expose the GStreamer plugin scanner
###############################################################################

RUN scanner="$( \
        find "${GSTREAMER_ROOT}" \
            -type f \
            -name gst-plugin-scanner \
            -print \
            -quit \
    )" && \
    test -n "${scanner}" && \
    test -x "${scanner}" && \
    mkdir -p /opt/intel/dlstreamer/bin && \
    ln -sfn "${scanner}" "${GST_PLUGIN_SCANNER}" && \
    test -x "${GST_PLUGIN_SCANNER}"

###############################################################################
# Configure and build DL Streamer
###############################################################################

RUN PKG_CONFIG_PATH="${GSTREAMER_ROOT}/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig" \
    CMAKE_PREFIX_PATH="${GSTREAMER_ROOT}:${OPENVINO_ROOT}:/usr" \
    cmake \
        -S "${DLS_SOURCE}" \
        -B "${DLS_BUILD}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/intel/dlstreamer \
        -DCMAKE_PREFIX_PATH="${GSTREAMER_ROOT};${OPENVINO_ROOT};/usr" \
        -DOpenVINO_DIR="${OpenVINO_DIR}" \
        -DCMAKE_C_FLAGS="-I${GSTREAMER_ROOT}/include/gstreamer-1.0" \
        -DCMAKE_CXX_FLAGS="-I${GSTREAMER_ROOT}/include/gstreamer-1.0" \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DOpenCL_INCLUDE_DIR=/usr/include \
        -DOpenCL_LIBRARY=/usr/lib/aarch64-linux-gnu/libOpenCL.so \
        -DENABLE_ITT=OFF \
        -DENABLE_VAAPI=ON \
        -DENABLE_SAMPLES=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_FUZZING=OFF \
        -DENABLE_REALSENSE=OFF \
        -DENABLE_GENAI=OFF \
        -DENABLE_AUDIO_INFERENCE_ELEMENTS=ON \
        -DENABLE_PAHO_INSTALLATION=OFF \
        -DENABLE_RDKAFKA_INSTALLATION=OFF \
        -DTREAT_WARNING_AS_ERROR=OFF && \
    PKG_CONFIG_PATH="${GSTREAMER_ROOT}/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig" \
    cmake --build "${DLS_BUILD}" \
        --parallel "${BUILD_JOBS}" && \
    cmake --install "${DLS_BUILD}"

RUN test -f "${DLS_BUILD_LIB}/libgstvideoanalytics.so" && \
    readelf -h "${DLS_BUILD_LIB}/libgstvideoanalytics.so" \
        | grep -q 'Machine:.*AArch64' && \
    grep -aqF \
        "POWER_SAVE profile activated" \
        "${DLS_BUILD_LIB}/libgstvideoanalytics.so" && \
    mkdir -p /opt/intel/dlstreamer/lib && \
    ln -sfn \
        "${DLS_BUILD_LIB}/libgstvideoanalytics.so" \
        /opt/intel/dlstreamer/lib/libgstvideoanalytics.so

RUN test -x "${GST_PLUGIN_SCANNER}" && \
    rm -f "${GST_REGISTRY}" && \
    gst-launch-1.0 --version && \
    gst-inspect-1.0 gvadetect > /tmp/gvadetect.inspect && \
    grep -E 'Filename|Version' /tmp/gvadetect.inspect && \
    loaded_plugin="$( \
        sed -n \
            's/^[[:space:]]*Filename[[:space:]]*//p' \
            /tmp/gvadetect.inspect \
        | head -1 \
    )" && \
    test "${loaded_plugin}" = "${DLS_BUILD_LIB}/libgstvideoanalytics.so" && \
    grep -aqF "POWER_SAVE profile activated" "${loaded_plugin}"

###############################################################################
# Image metadata
#
# Keep dynamic args/labels at the end so BUILD_TIMESTAMP does not invalidate
# all expensive dependency and compilation layers.
###############################################################################
ARG DLSTREAMER_COMMIT=unknown
ARG BUILD_TIMESTAMP=unknown

LABEL org.opencontainers.image.title="TEAR DL Streamer AArch64"
LABEL org.opencontainers.image.description="AArch64 DL Streamer 2026.1 runtime with TEAR POWER_SAVE enforcement"
LABEL org.opencontainers.image.revision="${DLSTREAMER_COMMIT}"
LABEL org.opencontainers.image.created="${BUILD_TIMESTAMP}"

WORKDIR /workspace
CMD ["/bin/bash"]
