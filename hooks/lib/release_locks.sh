#!/bin/bash

# Reviewed release inputs for reproducible build hooks. Update a lock only after
# independently reviewing the upstream release and its artifact hash.
release_lock_lookup() {
    local component="$1"

    RELEASE_LOCK_REPO=""
    RELEASE_LOCK_TAG=""
    RELEASE_LOCK_ASSET=""
    RELEASE_LOCK_SHA256=""

    case "$component" in
    yq)
        RELEASE_LOCK_REPO="mikefarah/yq"
        RELEASE_LOCK_TAG="v4.53.3"
        RELEASE_LOCK_ASSET="yq_linux_arm64"
        RELEASE_LOCK_SHA256="578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea"
        ;;
    jq)
        RELEASE_LOCK_REPO="jqlang/jq"
        RELEASE_LOCK_TAG="jq-1.8.2"
        RELEASE_LOCK_ASSET="jq-linux-arm64"
        RELEASE_LOCK_SHA256="8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309"
        ;;
    ecapture)
        RELEASE_LOCK_REPO="gojue/ecapture"
        RELEASE_LOCK_TAG="v2.5.2"
        RELEASE_LOCK_ASSET="ecapture-v2.5.2-android-arm64.tar.gz"
        RELEASE_LOCK_SHA256="3531f47f60a45c02662188fb151fa8bbf9c40e5c245ff293e5a50477b99df2d1"
        ;;
    zashboard)
        RELEASE_LOCK_REPO="Zephyruso/zashboard"
        RELEASE_LOCK_TAG="v3.16.0"
        RELEASE_LOCK_ASSET="dist-no-fonts.zip"
        RELEASE_LOCK_SHA256="1d8c7aca69e6ddead5e4fe6e92ceda23a499105f675d053362f7c9b53a9730f9"
        ;;
    *)
        return 1
        ;;
    esac
}

release_lock_is_valid() {
    [[ "$RELEASE_LOCK_REPO" == */* ]] &&
        [[ -n "$RELEASE_LOCK_TAG" ]] &&
        [[ "$RELEASE_LOCK_ASSET" != */* ]] &&
        [[ "$RELEASE_LOCK_SHA256" =~ ^[0-9a-f]{64}$ ]]
}
