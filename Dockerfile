FROM alpine:latest AS build

ARG BUILD

ARG NGX_MAINLINE_VER=1.29.4
ARG BORINGSSL_VER=main
ARG NGX_BROTLI=master
ARG NGX_HEADERS_MORE=v0.39
ARG NGX_NJS=0.9.4
ARG NGX_GEOIP2=3.4
ARG NGX_TLS_DYN_SIZE=nginx__dynamic_tls_records_1.29.2+.patch

WORKDIR /src

# Install the required packages

RUN apk add --no-cache \
        ca-certificates \
        build-base \
        patch \
        cmake \
        git \
        libtool \
        autoconf \
        automake \
        libatomic_ops-dev \
        zlib-dev \
        pcre2-dev \
        linux-headers \
        libxml2-dev \
        libxslt-dev \
        perl-dev \
        perl \
        curl-dev \
        geoip-dev \
        ninja \
        libunwind-dev \
        go \
        libmaxminddb-dev

# BoringSSL

RUN (git clone --depth 1 --recursive --branch "$BORINGSSL_VER" https://boringssl.googlesource.com/boringssl /src/boringssl \
        && cd /src/boringssl \
        && cmake -GNinja -B build -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release \
        && ninja -C build \
        && mkdir -p /src/boringssl/.openssl/lib \
        && ln -s /src/boringssl/include /src/boringssl/.openssl/include \
        && cp /src/boringssl/build/libcrypto.a /src/boringssl/.openssl/lib/ \
        && cp /src/boringssl/build/libssl.a /src/boringssl/.openssl/lib/)

# Modules

RUN (git clone --depth 1 --recursive --branch "$NGX_BROTLI" https://github.com/google/ngx_brotli /src/ngx_brotli \
        && git clone --depth 1 --recursive --branch "$NGX_HEADERS_MORE" https://github.com/openresty/headers-more-nginx-module /src/headers-more-nginx-module \
        && git clone --depth 1 --recursive --branch "$NGX_NJS" https://github.com/nginx/njs /src/njs \
        && git clone --depth 1 --recursive --branch "$NGX_GEOIP2" https://github.com/leev/ngx_http_geoip2_module /src/ngx_http_geoip2_module)

# Nginx

RUN (wget https://nginx.org/download/nginx-"$NGX_MAINLINE_VER".tar.gz -O - | tar xzC /src \
        && mv /src/nginx-"$NGX_MAINLINE_VER" /src/nginx \
        && wget https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/master/"$NGX_TLS_DYN_SIZE" -O /src/nginx/dynamic_tls_records.patch \
        && cd /src/nginx \
        && patch -p1 < dynamic_tls_records.patch)
RUN cd /src/nginx \
    && ./configure \
        --build=${BUILD} \
        --prefix=/etc/nginx \
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
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-threads \
        --with-file-aio \
        --with-libatomic \
        --with-pcre \
        --with-pcre-jit \
        --without-poll_module \
        --without-select_module \
        --with-openssl="/src/boringssl" \
        --with-cc-opt="-I/src/boringssl/.openssl/include -Wno-error -Wno-deprecated-declarations -fPIC" \
        --with-ld-opt="-L/src/boringssl/.openssl/lib -lssl -lcrypto -lstdc++" \
        --with-mail=dynamic \
        --with-mail_ssl_module \
        --with-stream=dynamic \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --with-stream_geoip_module=dynamic \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_ssl_module \
        --with-http_perl_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-http_realip_module \
        --with-http_gunzip_module \
        --with-http_addition_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --add-dynamic-module=/src/ngx_brotli \
        --add-dynamic-module=/src/headers-more-nginx-module \
        --add-dynamic-module=/src/njs/nginx \
        --add-dynamic-module=/src/ngx_http_geoip2_module \
    && touch /src/boringssl/include/openssl/ssl.h \
    && make -j "$(nproc)" \
    && make -j "$(nproc)" install \
    && rm /src/nginx/*.patch \
    && strip -s /usr/sbin/nginx \
    && strip -s /usr/lib/nginx/modules/*.so


# 运行阶段：构建精简镜像
FROM debian:bookworm-slim AS nginx-run


LABEL maintainer="liubei66 <1967780821@qq.com>"

# 配置软件源并安装运行时依赖
RUN set -eux; \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https \
        libpcre3 libpcre2-8-0 zlib1g libxslt1.1 libgd3 libgeoip1 libperl5.36 \
        libbrotli1 libzmq5 liblua5.1-0 libyaml-0-2 libxml2 libcurl3-gnutls \
        libjansson4 libmagic1 libtar0 libmaxminddb0 libjemalloc2 curl \
        iproute2 procps lsof dnsutils net-tools less jq \
        vim-tiny wget htop tcpdump strace rsync telnet; \
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
        touch /var/log/nginx/access.log \
        && touch /var/log/nginx/error.log \
        && ln -sf /dev/stdout /var/log/nginx/access.log \
        && ln -sf /dev/stderr /var/log/nginx/error.log; \
        chown -R nginx:nginx /var/lib/nginx /run/nginx /var/log/nginx; \
        chmod -R 755 /var/lib/nginx /run/nginx /var/log/nginx

# 复制编译产物

COPY --from=build /etc/nginx /etc/nginx
COPY --from=build /usr/sbin/nginx   /usr/sbin/nginx
COPY --from=build /usr/lib/nginx /usr/lib/nginx
COPY --from=build /usr/local/lib/perl5  /usr/local/lib/perl5
COPY --from=build /usr/lib/perl5/core_perl/perllocal.pod    /usr/lib/perl5/core_perl/perllocal.pod


# 暴露端口
EXPOSE 80 443

# 启动命令
CMD ["sh", "-c", "nginx -g 'daemon off;'"]