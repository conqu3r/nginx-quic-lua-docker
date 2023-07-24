# 构建阶段
FROM nginx AS build

WORKDIR /src

# 安装编译所需的软件包
RUN apt-get update && apt-get install -y git gcc make autoconf libtool perl libssl-dev \
    mercurial libperl-dev libpcre3-dev zlib1g-dev libxslt1-dev libgd-ocaml-dev luajit libluajit-5.1-dev libmaxminddb-dev

# 下载并安装 Lua 模块和 ngx-devel-kit、ngx_http_geoip2_module
RUN git clone https://github.com/openresty/lua-nginx-module && \
    git clone https://github.com/vision5/ngx_devel_kit && \
    git clone https://github.com/openresty/lua-resty-core && \
    git clone https://github.com/leev/ngx_http_geoip2_module 

ENV LUAJIT_LIB=/usr/lib/x86_64-linux-gnu
ENV LUAJIT_INC=/usr/include/luajit-2.1
ENV VERBOSE=1

# 下载 nginx 最新源码
RUN hg clone https://hg.nginx.org/nginx

# 打补丁:1、解决日志中文编码；2、新增https正向代理；
RUN cd nginx-quic && \
    curl -s https://raw.githubusercontent.com/openresty/openresty/master/patches/nginx-1.23.0-log_escape_non_ascii.patch | patch -p1 

# 编译 nginx
RUN cd nginx && \
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
      --with-http_image_filter_module \
      --with-http_v2_module \
      --with-ipv6 \
      --with-mail --with-mail_ssl_module \
      --with-stream --with-stream_realip_module \
      --with-stream_ssl_module --with-stream_ssl_preread_module \
      --with-http_v3_module --with-stream_quic_module \
      --add-module=../ngx_devel_kit \
      --add-module=../lua-nginx-module \
      --add-module=../ngx_http_geoip2_module \
      --with-debug --build=nginx-quic \
      --with-cc-opt="-Wno-error" && \
    make

# 最终阶段
FROM nginx

# 安装运行所需的软件包和 Lua 模块
RUN apt-get update --fix-missing && \
    apt-get install -y libluajit-5.1-2 sqlite3 libsqlite3-dev luarocks libmaxminddb0 && \
    luarocks install lua-sqlite3 && \
    luarocks install lua-resty-lrucache && \
    luarocks install lua-cjson && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 从构建阶段中复制生成的二进制文件
COPY --from=build /src/nginx-quic/objs/nginx /usr/sbin

# 从构建阶段中复制 Lua 模块
COPY --from=build /src/lua-resty-core/lib /usr/local/share/lua/5.1

# 修改时区
ENV TZ=Asia/Shanghai

# 复制 nginx 配置文件
#COPY nginx.conf /etc/nginx/nginx.conf

# 设置启动命令
CMD ["nginx", "-g", "daemon off;"]

# 设置信号
STOPSIGNAL SIGQUIT
