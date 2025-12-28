FROM alpine:latest AS nginx-build

ARG BUILD
ARG NGINX_VERSION=1.29.4
ARG NJS_VERSION=0.9.4
ARG LUAJIT_VERSION=2.1-20250826
ARG PCRE2_VERSION=10.47
ARG JEMALLOC_VERSION=5.3.0
ARG NGX_TLS_DYN_SIZE=nginx__dynamic_tls_records_1.29.2+.patch

WORKDIR /src

# 安装编译依赖
RUN apk add --no-cache \
        ca-certificates \
        build-base \
        patch \
        cmake \
        git \
        libtool \
        autoconf \
        automake \
        ninja \
        zlib-dev \
        pcre2-dev \
        linux-headers \
        libxml2-dev \
        libxslt-dev \
        perl-dev \
        perl \
        curl-dev \
        geoip-dev \
        libmaxminddb-dev \
        libbrotli-dev \
        libzmq-dev \
        yaml-dev \
        gd-dev \
        openssl-dev \
        luajit-dev \
        tar-dev \
        jansson-dev \
        libmagic-dev \
        go

# 编译安装 BoringSSL
RUN (git clone --depth 1 --recursive --branch main https://boringssl.googlesource.com/boringssl /src/boringssl \
        && cd /src/boringssl \
        && cmake -GNinja -B build -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release \
        && ninja -C build \
        && mkdir -p /src/boringssl/.openssl/lib \
        && ln -s /src/boringssl/include /src/boringssl/.openssl/include \
        && cp /src/boringssl/build/libcrypto.a /src/boringssl/.openssl/lib/ \
        && cp /src/boringssl/build/libssl.a /src/boringssl/.openssl/lib/)

# 安装 LuaJIT
RUN (wget -O LuaJIT-${LUAJIT_VERSION}.tar.gz https://github.com/openresty/luajit2/archive/refs/tags/v${LUAJIT_VERSION}.tar.gz \
        && tar -xzf LuaJIT-${LUAJIT_VERSION}.tar.gz \
        && cd luajit2-${LUAJIT_VERSION} \
        && make -j$(nproc) \
        && make install \
        && cd .. \
        && rm -rf luajit2-${LUAJIT_VERSION} LuaJIT-${LUAJIT_VERSION}.tar.gz)

# 编译安装 PCRE2
RUN (wget -O pcre2-${PCRE2_VERSION}.tar.gz https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz \
        && tar -xzf pcre2-${PCRE2_VERSION}.tar.gz \
        && cd pcre2-${PCRE2_VERSION} \
        && ./configure --enable-jit --enable-pcre2-16 --enable-pcre2-32 --enable-unicode --with-pic \
        && make -j$(nproc) \
        && make install \
        && cd .. \
        && rm -rf pcre2-${PCRE2_VERSION} pcre2-${PCRE2_VERSION}.tar.gz)

# 编译安装 Jemalloc
RUN (wget -O jemalloc-${JEMALLOC_VERSION}.tar.gz https://github.com/jemalloc/jemalloc/releases/download/${JEMALLOC_VERSION}/jemalloc-${JEMALLOC_VERSION}.tar.gz \
        && tar -xzf jemalloc-${JEMALLOC_VERSION}.tar.gz \
        && cd jemalloc-${JEMALLOC_VERSION} \
        && ./configure --with-pic \
        && make -j$(nproc) \
        && make install \
        && cd .. \
        && rm -rf jemalloc-${JEMALLOC_VERSION} jemalloc-${JEMALLOC_VERSION}.tar.gz)

# 编译安装 QuickJS
RUN (git clone https://github.com/bellard/quickjs /src/quickjs \
        && cd /src/quickjs \
        && CFLAGS='-fPIC' make libquickjs.a \
        && cd ..)

# 下载所有模块
RUN (git clone --depth 1 --branch master https://github.com/vision5/ngx_devel_kit.git /src/ngx_devel_kit \
        && git clone --depth 1 --branch master https://github.com/vozlt/nginx-module-vts.git /src/nginx-module-vts \
        && git clone --depth 1 --branch master https://github.com/ZigzagAK/ngx_dynamic_upstream.git /src/ngx_dynamic_upstream \
        && git clone --depth 1 --branch master https://github.com/Lax/traffic-accounting-nginx-module.git /src/traffic-accounting \
        && git clone --depth 1 --branch master https://github.com/openresty/array-var-nginx-module.git /src/array-var \
        && git clone --depth 1 --branch master https://github.com/google/ngx_brotli.git /src/ngx_brotli \
        && cd /src/ngx_brotli && git submodule update --init && cd .. \
        && git clone --depth 1 --branch master https://github.com/nginx-modules/ngx_cache_purge.git /src/ngx_cache_purge \
        && git clone --depth 1 --branch master https://github.com/AirisX/nginx_cookie_flag_module.git /src/nginx_cookie_flag \
        && git clone --depth 1 --branch master https://github.com/arut/nginx-dav-ext-module.git /src/nginx-dav-ext \
        && git clone --depth 1 --branch master https://github.com/openresty/echo-nginx-module.git /src/echo \
        && git clone --depth 1 --branch master https://github.com/openresty/encrypted-session-nginx-module.git /src/encrypted-session \
        && git clone --depth 1 --branch master https://github.com/openresty/headers-more-nginx-module.git /src/headers-more \
        && git clone --depth 1 --branch master https://github.com/openresty/lua-nginx-module.git /src/lua-nginx \
        && git clone --depth 1 --branch master https://github.com/openresty/lua-upstream-nginx-module.git /src/lua-upstream \
        && git clone --depth 1 --branch master https://github.com/openresty/redis2-nginx-module.git /src/redis2 \
        && git clone --depth 1 --branch master https://github.com/openresty/set-misc-nginx-module.git /src/set-misc \
        && git clone --depth 1 --branch master https://github.com/aperezdc/ngx-fancyindex.git /src/ngx-fancyindex \
        && git clone --depth 1 --branch master https://github.com/leev/ngx_http_geoip2_module.git /src/ngx_http_geoip2_module \
        && git clone --depth 1 --branch main https://github.com/kjdev/nginx-keyval.git /src/nginx-keyval \
        && git clone --depth 1 --branch master https://github.com/nginx-modules/nginx-log-zmq.git /src/nginx-log-zmq \
        && git clone --depth 1 --branch master https://github.com/nbs-system/naxsi.git /src/naxsi \
        && git clone --depth 1 --branch master https://github.com/slact/nchan.git /src/nchan \
        && git clone --depth 1 --branch master https://github.com/FRiCKLE/ngx_slowfs_cache.git /src/ngx_slowfs_cache \
        && git clone --depth 1 --branch master https://github.com/fdintino/nginx-upload-module.git /src/nginx-upload \
        && git clone --depth 1 --branch master https://github.com/masterzen/nginx-upload-progress-module.git /src/nginx-upload-progress \
        && git clone --depth 1 --branch master https://github.com/runenyUnidex/nginx-upstream-fair.git /src/nginx-upstream-fair \
        && git clone --depth 1 --branch master https://github.com/RekGRpth/ngx_upstream_jdomain.git /src/ngx_upstream_jdomain \
        && git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_zstd_module.git /src/zstd-nginx \
        && git clone --depth 1 --branch master https://github.com/arut/nginx-rtmp-module.git /src/nginx-rtmp \
        && git clone --depth 1 --branch master https://github.com/gi0baro/nginx-upstream-dynamic-servers.git /src/nginx-upstream-dynamic-servers \
        && git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_upstream_check_module.git /src/ngx_upstream_check \
        && git clone --depth 1 --branch ${NJS_VERSION} https://github.com/nginx/njs.git /src/njs)

# 下载并应用 upstream_check 补丁
RUN (wget -O /tmp/upstream_check.patch https://raw.githubusercontent.com/yaoweibin/nginx_upstream_check_module/master/check_1.20.1+.patch)

# 下载并编译 zstd
RUN (mkdir -p /usr/local/zstd-pic \
        && cd /tmp \
        && ZSTD_VERSION="1.5.7" \
        && wget -O zstd-${ZSTD_VERSION}.tar.gz https://github.com/facebook/zstd/archive/refs/tags/v${ZSTD_VERSION}.tar.gz \
        && tar -xzf zstd-${ZSTD_VERSION}.tar.gz \
        && cd zstd-${ZSTD_VERSION} \
        && make clean \
        && CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" make -j$(nproc) PREFIX=/usr/local/zstd-pic \
        && make PREFIX=/usr/local/zstd-pic install \
        && cd .. \
        && rm -rf zstd-${ZSTD_VERSION} zstd-${ZSTD_VERSION}.tar.gz)

# 下载 Nginx 源码并应用补丁
RUN (wget https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -O - | tar xzC /src \
        && mv /src/nginx-${NGINX_VERSION} /src/nginx \
        && wget https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/master/${NGX_TLS_DYN_SIZE} -O /src/nginx/dynamic_tls_records.patch \
        && cd /src/nginx \
        && patch -p1 < dynamic_tls_records.patch)

# 配置并编译 Nginx
RUN cd /src/nginx \
    && ./configure \
        --build=${BUILD} \
        --prefix=/var/lib/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/run/nginx/nginx.pid \
        --lock-path=/run/nginx/nginx.lock \
        --http-client-body-temp-path=/var/lib/nginx/tmp/client_body \
        --http-proxy-temp-path=/var/lib/nginx/tmp/proxy \
        --http-fastcgi-temp-path=/var/lib/nginx/tmp/fastcgi \
        --http-uwsgi-temp-path=/var/lib/nginx/tmp/uwsgi \
        --http-scgi-temp-path=/var/lib/nginx/tmp/scgi \
        --with-perl_modules_path=/usr/lib/perl5/vendor_perl \
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-threads \
        --with-file-aio \
        --with-libatomic \
        --with-pcre-jit \
        --without-poll_module \
        --without-select_module \
        --with-openssl="/src/boringssl" \
        --with-cc-opt="-I/src/boringssl/.openssl/include -I/usr/local/include/luajit-2.1 -I/usr/local/zstd-pic/include -I/usr/local/include -I/src/quickjs -Wno-error -Wno-deprecated-declarations -fPIC" \
        --with-ld-opt="-L/src/boringssl/.openssl/lib -L/usr/local/lib -L/usr/local/zstd-pic/lib -L/src/quickjs -L/usr/local/lib -Wl,-rpath,/usr/local/lib:/usr/local/zstd-pic/lib:/usr/local/lib -lssl -lcrypto -lstdc++ -lzstd -lquickjs -lz -lpcre2-8 -ljemalloc -lpthread -Wl,-Bsymbolic-functions" \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_xslt_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_degradation_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --with-http_perl_module=dynamic \
        --with-mail=dynamic \
        --with-mail_ssl_module \
        --with-stream=dynamic \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_geoip_module=dynamic \
        --with-stream_ssl_preread_module \
        --add-dynamic-module=/src/njs/nginx \
        --add-dynamic-module=/src/ngx_devel_kit \
        --add-dynamic-module=/src/nginx-module-vts \
        --add-dynamic-module=/src/ngx_dynamic_upstream \
        --add-dynamic-module=/src/traffic-accounting \
        --add-dynamic-module=/src/array-var \
        --add-dynamic-module=/src/ngx_brotli \
        --add-dynamic-module=/src/ngx_cache_purge \
        --add-dynamic-module=/src/nginx_cookie_flag \
        --add-dynamic-module=/src/nginx-dav-ext \
        --add-dynamic-module=/src/echo \
        --add-dynamic-module=/src/encrypted-session \
        --add-dynamic-module=/src/ngx-fancyindex \
        --add-dynamic-module=/src/ngx_http_geoip2_module \
        --add-dynamic-module=/src/headers-more \
        --add-dynamic-module=/src/nginx-keyval \
        --add-dynamic-module=/src/nginx-log-zmq \
        --add-dynamic-module=/src/lua-nginx \
        --add-dynamic-module=/src/lua-upstream \
        --add-dynamic-module=/src/naxsi/naxsi_src \
        --add-dynamic-module=/src/nchan \
        --add-dynamic-module=/src/redis2 \
        --add-dynamic-module=/src/set-misc \
        --add-dynamic-module=/src/ngx_slowfs_cache \
        --add-dynamic-module=/src/nginx-upload \
        --add-dynamic-module=/src/nginx-upload-progress \
        --add-dynamic-module=/src/nginx-upstream-fair \
        --add-dynamic-module=/src/ngx_upstream_jdomain \
        --add-dynamic-module=/src/zstd-nginx \
        --add-dynamic-module=/src/nginx-rtmp \
        --add-dynamic-module=/src/nginx-upstream-dynamic-servers \
        --add-dynamic-module=/src/ngx_upstream_check \
    && touch /src/boringssl/include/openssl/ssl.h \
    && make -j "$(nproc)" \
    && make -j "$(nproc)" install \
    && make clean \
    && rm -rf /src/nginx/*.patch \
    && strip -s /usr/sbin/nginx \
    && strip -s /usr/lib/nginx/modules/*.so \
    && for module in /usr/lib/nginx/modules/*.so; do \
         module_name=$(basename $module .so); \
         echo "load_module $module;" >$module_name.load; \
    done


# 运行阶段：构建精简镜像
FROM debian:bookworm-slim AS nginx-run

ARG NGINX_VERSION

LABEL maintainer="liubei66 <1967780821@qq.com>"
LABEL description="Nginx ${NGINX_VERSION} with BoringSSL + custom modules + PCRE2 JIT + Jemalloc + HTTP3/QUIC + TLS Dynamic Size"

# 安装运行时依赖并创建系统用户
RUN set -eux; \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https \
        libpcre3 libpcre2-8-0 zlib1g libxslt1.1 libgd3 libgeoip1 libperl5.36 \
        libbrotli1 libzmq5 liblua5.1-0 libyaml-0-2 libxml2 libcurl3-gnutls \
        libjansson4 libmagic1 libtar0 libmaxminddb0 libjemalloc2 libstdc++6 \
        iproute2 procps curl lsof dnsutils net-tools less jq vim wget htop; \
    update-ca-certificates; \
    rm -f /etc/apt/sources.list.d/*; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    rm -rf /var/lib/apt/lists/* ; \
    groupadd -r nginx && useradd -r -g nginx -s /sbin/nologin -d /var/lib/nginx nginx; \
    mkdir -p \
        /var/lib/nginx/tmp/client_body \
        /var/lib/nginx/tmp/proxy \
        /var/lib/nginx/tmp/fastcgi \
        /var/lib/nginx/tmp/uwsgi \
        /var/lib/nginx/tmp/scgi \
        /run/nginx \
        /etc/nginx/conf.d \
        /var/log/nginx; \
    chown -R nginx:nginx /var/lib/nginx /run/nginx /var/log/nginx; \
    chmod -R 755 /var/lib/nginx /run/nginx /var/log/nginx

# 复制编译产物到运行镜像
COPY --from=nginx-build /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-build /usr/lib/nginx /usr/lib/nginx
COPY --from=nginx-build /etc/nginx /etc/nginx
COPY --from=nginx-build /var/lib/nginx /var/lib/nginx
COPY --from=nginx-build /usr/local /usr/local
COPY --from=nginx-build /etc/ld.so.conf.d/ /etc/ld.so.conf.d/

# 暴露服务端口（TCP+UDP，适配HTTP3/QUIC）
EXPOSE 80 443 443/udp

# 启动Nginx服务
CMD ["sh", "-c", "nginx -g 'daemon off;'"]