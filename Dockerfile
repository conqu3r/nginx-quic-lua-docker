ARG NGINX_FROM_IMAGE=nginx:1.31.9-alpine@sha256:90b6bd2aec278b16b98221d64deb1d6d35d164567f507ab0716e6053878315aa
FROM ${NGINX_FROM_IMAGE} AS base
RUN apk upgrade --no-cache

# Temporary BusyBox wget fix until Alpine ships a patched package.
FROM base AS busybox-backport
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
RUN mkdir /tmp/busybox-backport \
    && if apk info -e "busybox=1.37.0-r31" > /dev/null; then \
        apk add --no-cache alpine-sdk linux-headers openssl-dev perl utmps-dev utmps-static; \
        aports_commit=c3ef5d10e6ef6528852c51f0564963e2f8c1be19; \
        patch_file=wget-CVE-2025-60876.patch; \
        patch_sha512=c0eb42640d4903c6aece020031e49147ff3feda174ac91234203b51eb6f07dee8770456cb9b77fc6fc6268f893f6d5e8a947d60427ad304f542bf64544e08d73; \
        git init -q /aports; \
        git -C /aports remote add origin https://github.com/alpinelinux/aports.git; \
        git -C /aports sparse-checkout set main/busybox; \
        git -C /aports -c protocol.version=2 fetch --filter=blob:none --depth=1 origin "$aports_commit"; \
        git -C /aports checkout --detach "$aports_commit"; \
        cd /aports/main/busybox; \
        curl -fsSL --retry 3 -o "$patch_file" \
            https://sources.debian.org/data/main/b/busybox/1%3A1.37.0-10.1/debian/patches/wget-disallow-control-chars-in-URLs-CVE-2025-60876.patch; \
        printf '%s  %s\n' "$patch_sha512" "$patch_file" | sha512sum -c -; \
        sed -i \
            -e 's/^pkgrel=31$/pkgrel=32/' \
            -e "/^source=\"/a\\\t$patch_file" \
            -e "/  busybox-1[.]37[.]0[.]tar[.]bz2$/a\\\t$patch_sha512  $patch_file" APKBUILD; \
        abuild-keygen -an; \
        cp "$HOME"/.abuild/*.rsa.pub /etc/apk/keys/; \
        apk update; \
        JOBS=2 SETFATTR=true abuild -F -r -K -P /packages; \
        cd "/packages/main/$(apk --print-arch)"; \
        cp busybox-1.37.0-r32.apk busybox-binsh-1.37.0-r32.apk ssl_client-1.37.0-r32.apk \
            "$HOME"/.abuild/*.rsa.pub /tmp/busybox-backport/; \
    fi

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

RUN --mount=type=bind,from=busybox-backport,source=/tmp/busybox-backport,target=/tmp/busybox-backport \
    set -e; \
    if [ -f /tmp/busybox-backport/busybox-1.37.0-r32.apk ]; then \
        cp -R /etc/apk/keys /tmp/apk-keys; \
        cp /tmp/busybox-backport/*.rsa.pub /tmp/apk-keys/; \
        apk add --no-cache --keys-dir /tmp/apk-keys /tmp/busybox-backport/*.apk; \
        rm -r /tmp/apk-keys; \
    fi
