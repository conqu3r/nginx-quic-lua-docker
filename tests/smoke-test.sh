#!/bin/sh
set -eu

image=${1:?Usage: smoke-test.sh IMAGE}
client=nginx-quic-lua:smoke-client
fixture=$(mktemp -d)
container=

cleanup() {
    if [ -n "$container" ]; then
        docker rm -f "$container" > /dev/null || true
    fi
    rm -r "$fixture"
}
trap cleanup EXIT

# Debian's backports curl supports HTTP/3 via ngtcp2. Build the client before
# starting the isolated server and client network namespace.
docker build -t "$client" - <<'DOCKERFILE'
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
RUN sed -i '/^Suites:/s/trixie trixie-updates/trixie trixie-updates trixie-backports/' /etc/apt/sources.list.d/debian.sources \
    && apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends -t trixie-backports curl \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost' -keyout "$fixture/tls.key" -out "$fixture/tls.crt" 2>/dev/null

cat > "$fixture/nginx.conf" <<'NGINX'
load_module modules/ndk_http_module.so;
load_module modules/ngx_http_lua_module.so;
load_module modules/ngx_stream_lua_module.so;
load_module modules/ngx_http_geoip2_module.so;
load_module modules/ngx_stream_geoip2_module.so;
load_module modules/ngx_http_js_module.so;
load_module modules/ngx_stream_js_module.so;
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;

user nginx;
worker_processes 1;
error_log stderr;
events {}
http {
    access_log off;
    server {
        listen 127.0.0.1:8443 ssl;
        listen 127.0.0.1:8443 quic;
        http2 on;
        ssl_certificate /tmp/smoke/tls.crt;
        ssl_certificate_key /tmp/smoke/tls.key;
        location = /health {
            content_by_lua_block {
                ngx.say("lua-ok")
            }
        }
    }
}
NGINX

container=$(docker create --network none --entrypoint /bin/sh "$image" -ec '
    nginx -t -c /tmp/smoke/nginx.conf
    exec nginx -c /tmp/smoke/nginx.conf -g "daemon off;"
')
docker cp "$fixture" "$container:/tmp/smoke"
docker start "$container" > /dev/null

if ! response=$(docker run --rm --network "container:$container" -i "$client" \
    curl --noproxy '*' --fail --silent --show-error --retry 5 --retry-connrefused \
    --connect-timeout 2 --max-time 5 --cacert /dev/stdin --ipv4 --http3-only \
    --write-out ' HTTP/%{http_version}' https://localhost:8443/health < "$fixture/tls.crt"); then
    docker logs "$container"
    exit 1
fi

expected=$(printf 'lua-ok\n HTTP/3')
if [ "$response" != "$expected" ]; then
    printf 'Unexpected HTTP/3 response: %s\n' "$response" >&2
    exit 1
fi
printf 'NGINX loaded all modules and served the Lua response over HTTP/3.\n'
