#!/bin/bash
# Remove build_output/. The musl toolchain extracts a read-only lib/
# directory, so chmod is required before rm.

set -e

declare -r OUTPUT_DIR="./build_output"

if [[ ! -e ${OUTPUT_DIR} ]]; then
    echo "nothing to clean (${OUTPUT_DIR})"
    exit 0
fi

if ! chmod -R u+w "${OUTPUT_DIR}" 2>/dev/null ; then
    sudo chmod -R u+w "${OUTPUT_DIR}"
fi

if ! rm -rf "${OUTPUT_DIR}" ; then
    sudo rm -rf "${OUTPUT_DIR}"
fi
