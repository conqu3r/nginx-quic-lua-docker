ARG NGINX_FROM_IMAGE=nginx:1.31.9-alpine@sha256:90b6bd2aec278b16b98221d64deb1d6d35d164567f507ab0716e6053878315aa
FROM ${NGINX_FROM_IMAGE} AS base
RUN apk upgrade --no-cache

FROM base AS builder
ARG ENABLED_MODULES="geoip2 ndk lua njs brotli"
# Official nginx/docker-nginx mainline/alpine source checksum for pkg-oss 1.31.9-1.
ARG PKG_OSS_SHA512=220da8433bf53265cf51abeaa0b6fdd9b6c77d16ee75340cb7bfd6412513d4d0a5b82e38bdf24a0343956906ea43748eb9c8615e917f6488915c7d6b69ccb8c0
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache \
        abuild coreutils curl findutils g++ git libxml2-utils libxslt linux-headers \
        make musl-dev openssl openssl-dev pcre2-dev unzip xz zlib-dev \
    && printf '%s\n' '#!/bin/sh' 'SETFATTR=true exec /usr/bin/abuild -F "$@"' > /usr/local/bin/abuild \
    && chmod +x /usr/local/bin/abuild

RUN curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/nginx/pkg-oss/archive/${NGINX_VERSION}-${PKG_RELEASE}.tar.gz" -o /tmp/pkg-oss.tar.gz \
    && printf '%s  %s\n' "$PKG_OSS_SHA512" /tmp/pkg-oss.tar.gz | sha512sum -c - \
    && mkdir -p /pkg-oss /tmp/packages \
    && tar -xzf /tmp/pkg-oss.tar.gz -C /pkg-oss --strip-components=1 \
    && rm /tmp/pkg-oss.tar.gz

COPY . /modules/
WORKDIR /pkg-oss/alpine

RUN set -f; \
    for module in $ENABLED_MODULES; do \
        case "$module" in \
            *[!a-zA-Z0-9_.-]*) echo "Invalid module name: $module" >&2; exit 1 ;; \
        esac; \
        if [ -d "/modules/$module" ]; then \
            test -s "/modules/$module/source" || { echo "Missing source for $module" >&2; exit 1; }; \
            if [ -s "/modules/$module/build-deps" ]; then \
                apk add --no-cache $(cat "/modules/$module/build-deps"); \
            fi; \
            if [ -x "/modules/$module/prebuild" ]; then \
                "/modules/$module/prebuild"; \
            fi; \
            /pkg-oss/build_module.sh -v "$NGINX_VERSION" -f -y -o /tmp/packages \
                -n "$module" $(cat "/modules/$module/source"); \
        elif apk info -e "nginx-module-$module" > /dev/null; then \
            echo "Using nginx-module-$module from the base image"; \
        elif make list | awk -v module="$module" '$1 == module { found = 1 } END { exit !found }'; then \
            make "abuild-module-$module"; \
            build_deps=$(. "./abuild-module-$module/APKBUILD"; printf '%s\n' "$makedepends"); \
            apk add --no-cache $build_deps; \
            make "module-$module"; \
            find "$HOME/packages" -type f -name "nginx-module-$module-${NGINX_VERSION}*.apk" \
                -exec mv {} /tmp/packages/ \;; \
        else \
            echo "Unknown NGINX module: $module" >&2; exit 1; \
        fi; \
    done; \
    if [ -f "$HOME/.abuild/abuild-key.rsa.pub" ]; then \
        cp "$HOME/.abuild/abuild-key.rsa.pub" /tmp/packages/; \
    fi

FROM base
RUN --mount=type=bind,from=builder,source=/tmp/packages,target=/tmp/packages \
    set -e; \
    set -- /tmp/packages/nginx-module-*-${NGINX_VERSION}*.apk; \
    if [ -f "$1" ]; then \
        cp -R /etc/apk/keys /tmp/apk-keys; \
        cp /tmp/packages/abuild-key.rsa.pub /tmp/apk-keys/; \
        apk add --no-cache --keys-dir /tmp/apk-keys "$@"; \
        rm -r /tmp/apk-keys; \
    fi
