FROM nginx AS build

WORKDIR /src
RUN apt-get update && apt-get install -y git gcc make autoconf libtool perl libssl-dev && \
    apt-get install -y mercurial libperl-dev libpcre3-dev zlib1g-dev libxslt1-dev libgd-ocaml-dev libgeoip-dev luajit libluajit-5.1-dev
ENV LUAJIT_LIB=/usr/lib/x86_64-linux-gnu
ENV LUAJIT_INC=/usr/include/luajit-2.1

RUN git -c http.sslVerify=false clone https://github.com/openresty/lua-nginx-module && \
    git -c http.sslVerify=false clone https://github.com/vision5/ngx_devel_kit && \
    git -c http.sslVerify=false clone https://github.com/openresty/lua-resty-core

RUN export VERBOSE=1 && \
    hg clone -b quic https://hg.nginx.org/nginx-quic && \
    cd nginx-quic && \
    auto/configure \
      --sbin-path=/usr/sbin/nginx \
      --modules-path=/usr/lib/nginx/modules \
      --conf-path=/etc/nginx/nginx.conf \
      --error-log-path=/var/log/nginx/error.log \
      --http-log-path=/var/log/nginx/access.log \
      --pid-path=/var/run/nginx.pid \
      --lock-path=/var/run/nginx.lock \
      --http-client-body-temp-path=/var/cache/nginx/client_temp \
      --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
      --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \ 
      --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
      --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
      --user=root \
      --with-compat \
      --with-file-aio \
      --with-threads \
      --with-http_addition_module \
      --with-http_auth_request_module \
      --with-http_dav_module \
      --with-http_flv_module \
      --with-http_gunzip_module \
      --with-http_gzip_static_module \
      --with-http_mp4_module \
      --with-http_random_index_module \
      --with-http_realip_module \
      --with-http_secure_link_module \
      --with-http_slice_module \
      --with-http_ssl_module \
      --with-http_stub_status_module \
      --with-http_sub_module \
      --with-http_v2_module \
      --with-ipv6 \
      --with-mail --with-mail_ssl_module \
      --with-stream --with-stream_realip_module \
      --with-stream_ssl_module --with-stream_ssl_preread_module \
      --with-http_v3_module --with-stream_quic_module \
      --add-module=../ngx_devel_kit \
      --add-module=../lua-nginx-module \
      --with-debug --build=nginx-quic \
      --with-cc-opt="-Wno-error" && \
    make

FROM nginx
COPY --from=build /src/nginx-quic/objs/nginx /usr/sbin
RUN apt-get update --fix-missing && \
    apt-get install -y libluajit-5.1-2 sqlite3 libsqlite3-dev luarocks && \
    luarocks install lua-sqlite3 && \
    luarocks install lua-resty-lrucache && \
    apt-get clean
COPY --from=build /src/lua-resty-core/lib /usr/local/share/lua/5.1

CMD ["/usr/sbin/nginx", "-g", "daemon off;", "-c", "/etc/nginx/nginx.conf"]

STOPSIGNAL SIGQUIT
