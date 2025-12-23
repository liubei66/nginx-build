# 全局定义构建参数（在所有FROM指令之前）
ARG NGINX_VERSION=1.29.4
ARG NJS_VERSION=0.9.4
ARG LUAJIT_VERSION=2.1-20250826
ARG LUAJIT_TAR=LuaJIT-${LUAJIT_VERSION}.tar.gz
ARG LUAJIT_URL=https://github.com/openresty/luajit2/archive/refs/tags/v${LUAJIT_VERSION}.tar.gz

# 构建阶段：编译nginx（基于Debian Bookworm，阿里云源+优化依赖+修复路径）
FROM debian:bookworm-slim AS nginx-build

ARG NGINX_VERSION
ARG NJS_VERSION
ARG LUAJIT_VERSION
ARG LUAJIT_TAR
ARG LUAJIT_URL

# 设置环境变量（传递构建参数+编译优化）
ENV NGINX_VERSION=${NGINX_VERSION} \
    NJS_VERSION=${NJS_VERSION} \
    LUAJIT_INC=/usr/local/include/luajit-2.1 \
    LUAJIT_LIB=/usr/local/lib \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/pkgconfig \
    GIT_SSL_NO_VERIFY=1 \
    MAKEFLAGS="-j$(nproc)"

# 配置阿里云源+安装基础依赖（合并RUN减少层+修复CA证书逻辑）
RUN set -eux; \
    rm -f /etc/apt/sources.list.d/* && \
    echo "deb http://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware" >/etc/apt/sources.list; \
    echo "deb http://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware" >>/etc/apt/sources.list; \
    echo "deb http://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware" >>/etc/apt/sources.list; \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https \
    wget git gcc g++ make patch unzip \
    libpcre3-dev zlib1g-dev libssl-dev libxslt1-dev libgd-dev libgeoip-dev \
    libperl-dev libbrotli-dev libzmq3-dev liblua5.1-dev libyaml-dev libxml2-dev \
    libcurl4-openssl-dev libjansson-dev libmagic-dev libtar-dev libmaxminddb-dev \
    libxslt-dev libgd-dev libgeoip-dev libperl-dev libmail-dkim-perl \
    libnginx-mod-http-dav-ext libssl-dev libpcre2-dev; \
    update-ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /usr/src/nginx && \
    mkdir -p /usr/src/nginx/src && \
    mkdir -p /usr/src/nginx/modules && \
    chmod -R 755 /usr/src/nginx

# 下载并解压Nginx源码（移除MD5验证，确保目标目录存在）
RUN set -eux; \
    mkdir -p /usr/src/nginx/src; \
    wget -O /usr/src/nginx/nginx-${NGINX_VERSION}.tar.gz \
        https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz; \
    tar -zxf /usr/src/nginx/nginx-${NGINX_VERSION}.tar.gz -C /usr/src/nginx/src --strip-components=1; \
    rm -f /usr/src/nginx/nginx-${NGINX_VERSION}.tar.gz

# 下载并解压njs模块（修复路径问题：使用绝对路径解压）
RUN set -eux; \
    NJS_TAR="/usr/src/nginx/njs-${NJS_VERSION}.tar.gz"; \
    wget -O ${NJS_TAR} https://ghproxy.net/https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz; \
    tar -zxf ${NJS_TAR} -C /usr/src/nginx/modules; \
    mv /usr/src/nginx/modules/njs-${NJS_VERSION} /usr/src/nginx/modules/njs; \
    rm -f ${NJS_TAR}; \
    [ -d "/usr/src/nginx/modules/njs/nginx" ] || (echo "njs模块目录异常，构建失败" && exit 1)

# 安装LuaJIT（修复下载地址+优化编译）
RUN set -eux; \
    LUAJIT_TAR_PATH="/usr/src/nginx/${LUAJIT_TAR}"; \
    wget -O ${LUAJIT_TAR_PATH} ${LUAJIT_URL}; \
    tar -zxf ${LUAJIT_TAR_PATH} -C /usr/src/nginx/modules; \
    mv /usr/src/nginx/modules/luajit2-${LUAJIT_VERSION} /usr/src/nginx/modules/luajit; \
    cd /usr/src/nginx/modules/luajit; \
    make PREFIX=/usr/local install; \
    echo "${LUAJIT_LIB}" > /etc/ld.so.conf.d/luajit.conf; \
    ldconfig; \
    rm -rf ${LUAJIT_TAR_PATH} /usr/src/nginx/modules/luajit

# 独立克隆各模块（恢复原始独立RUN指令）
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/vision5/ngx_devel_kit.git /usr/src/nginx/modules/ngx_devel_kit || \
    (echo "克隆ngx_devel_kit失败，重试..." && git clone --depth 1 --branch master https://github.com/vision5/ngx_devel_kit.git /usr/src/nginx/modules/ngx_devel_kit)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/vozlt/nginx-module-vts.git /usr/src/nginx/modules/ngx_dynamic_healthcheck || \
    (echo "克隆ngx_dynamic_healthcheck失败，重试..." && git clone --depth 1 --branch master https://github.com/vozlt/nginx-module-vts.git /usr/src/nginx/modules/ngx_dynamic_healthcheck)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/cubicdaiya/ngx_dynamic_upstream.git /usr/src/nginx/modules/ngx_dynamic_upstream || \
    (echo "克隆ngx_dynamic_upstream失败，重试..." && git clone --depth 1 --branch master https://github.com/cubicdaiya/ngx_dynamic_upstream.git /usr/src/nginx/modules/ngx_dynamic_upstream)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/Lax/traffic-accounting-nginx-module.git /usr/src/nginx/modules/traffic-accounting || \
    (echo "克隆traffic-accounting失败，重试..." && git clone --depth 1 --branch master https://github.com/Lax/traffic-accounting-nginx-module.git /usr/src/nginx/modules/traffic-accounting)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/array-var-nginx-module.git /usr/src/nginx/modules/array-var || \
    (echo "克隆array-var失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/array-var-nginx-module.git /usr/src/nginx/modules/array-var)

RUN set -eux; \
    git clone --depth 1 --branch main https://github.com/kjdev/nginx-auth-jwt.git /usr/src/nginx/modules/nginx-auth-jwt || \
    (echo "克隆nginx-auth-jwt失败，重试..." && git clone --depth 1 --branch main https://github.com/kjdev/nginx-auth-jwt.git /usr/src/nginx/modules/nginx-auth-jwt)

# 压缩/缓存模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/google/ngx_brotli.git /usr/src/nginx/modules/ngx_brotli || \
    (echo "克隆ngx_brotli失败，重试..." && git clone --depth 1 --branch master https://github.com/google/ngx_brotli.git /usr/src/nginx/modules/ngx_brotli); \
    cd /usr/src/nginx/modules/ngx_brotli && git submodule update --init

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/FRiCKLE/ngx_cache_purge.git /usr/src/nginx/modules/ngx_cache_purge || \
    (echo "克隆ngx_cache_purge失败，重试..." && git clone --depth 1 --branch master https://github.com/FRiCKLE/ngx_cache_purge.git /usr/src/nginx/modules/ngx_cache_purge)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/AirisX/nginx_cookie_flag_module.git /usr/src/nginx/modules/nginx_cookie_flag || \
    (echo "克隆nginx_cookie_flag失败，重试..." && git clone --depth 1 --branch master https://github.com/AirisX/nginx_cookie_flag_module.git /usr/src/nginx/modules/nginx_cookie_flag)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/arut/nginx-dav-ext-module.git /usr/src/nginx/modules/nginx-dav-ext || \
    (echo "克隆nginx-dav-ext失败，重试..." && git clone --depth 1 --branch master https://github.com/arut/nginx-dav-ext-module.git /usr/src/nginx/modules/nginx-dav-ext)

# OpenResty生态模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/echo-nginx-module.git /usr/src/nginx/modules/echo || \
    (echo "克隆echo失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/echo-nginx-module.git /usr/src/nginx/modules/echo)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/encrypted-session-nginx-module.git /usr/src/nginx/modules/encrypted-session || \
    (echo "克隆encrypted-session失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/encrypted-session-nginx-module.git /usr/src/nginx/modules/encrypted-session)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/headers-more-nginx-module.git /usr/src/nginx/modules/headers-more || \
    (echo "克隆headers-more失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/headers-more-nginx-module.git /usr/src/nginx/modules/headers-more)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/lua-nginx-module.git /usr/src/nginx/modules/lua-nginx || \
    (echo "克隆lua-nginx失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/lua-nginx-module.git /usr/src/nginx/modules/lua-nginx)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/lua-upstream-nginx-module.git /usr/src/nginx/modules/lua-upstream || \
    (echo "克隆lua-upstream失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/lua-upstream-nginx-module.git /usr/src/nginx/modules/lua-upstream)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/redis2-nginx-module.git /usr/src/nginx/modules/redis2 || \
    (echo "克隆redis2失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/redis2-nginx-module.git /usr/src/nginx/modules/redis2)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/set-misc-nginx-module.git /usr/src/nginx/modules/set-misc || \
    (echo "克隆set-misc失败，重试..." && git clone --depth 1 --branch master https://github.com/openresty/set-misc-nginx-module.git /usr/src/nginx/modules/set-misc)

# 其他实用模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/aperezdc/ngx-fancyindex.git /usr/src/nginx/modules/ngx-fancyindex || \
    (echo "克隆ngx-fancyindex失败，重试..." && git clone --depth 1 --branch master https://github.com/aperezdc/ngx-fancyindex.git /usr/src/nginx/modules/ngx-fancyindex)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/leev/ngx_http_geoip2_module.git /usr/src/nginx/modules/ngx_http_geoip2_module || \
    (echo "克隆ngx_http_geoip2_module失败，重试..." && git clone --depth 1 --branch master https://github.com/leev/ngx_http_geoip2_module.git /usr/src/nginx/modules/ngx_http_geoip2_module)

RUN set -eux; \
    git clone --depth 1 --branch main https://github.com/kjdev/nginx-keyval.git /usr/src/nginx/modules/nginx-keyval || \
    (echo "克隆nginx-keyval失败，重试..." && git clone --depth 1 --branch main https://github.com/kjdev/nginx-keyval.git /usr/src/nginx/modules/nginx-keyval)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/nginx-modules/nginx-log-zmq.git /usr/src/nginx/modules/nginx-log-zmq || \
    (echo "克隆nginx-log-zmq失败，重试..." && git clone --depth 1 --branch master https://github.com/nginx-modules/nginx-log-zmq.git /usr/src/nginx/modules/nginx-log-zmq)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/nbs-system/naxsi.git /usr/src/nginx/modules/naxsi || \
    (echo "克隆naxsi失败，重试..." && git clone --depth 1 --branch master https://github.com/nbs-system/naxsi.git /usr/src/nginx/modules/naxsi)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/slact/nchan.git /usr/src/nginx/modules/nchan || \
    (echo "克隆nchan失败，重试..." && git clone --depth 1 --branch master https://github.com/slact/nchan.git /usr/src/nginx/modules/nchan)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/FRiCKLE/ngx_slowfs_cache.git /usr/src/nginx/modules/ngx_slowfs_cache || \
    (echo "克隆ngx_slowfs_cache失败，重试..." && git clone --depth 1 --branch master https://github.com/FRiCKLE/ngx_slowfs_cache.git /usr/src/nginx/modules/ngx_slowfs_cache)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/fdintino/nginx-upload-module.git /usr/src/nginx/modules/nginx-upload || \
    (echo "克隆nginx-upload失败，重试..." && git clone --depth 1 --branch master https://github.com/fdintino/nginx-upload-module.git /usr/src/nginx/modules/nginx-upload)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/masterzen/nginx-upload-progress-module.git /usr/src/nginx/modules/nginx-upload-progress || \
    (echo "克隆nginx-upload-progress失败，重试..." && git clone --depth 1 --branch master https://github.com/masterzen/nginx-upload-progress-module.git /usr/src/nginx/modules/nginx-upload-progress)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/runenyUnidex/nginx-upstream-fair.git /usr/src/nginx/modules/nginx-upstream-fair || \
    (echo "克隆nginx-upstream-fair失败，重试..." && git clone --depth 1 --branch master https://github.com/gnosek/nginx-upstream-fair.git /usr/src/nginx/modules/nginx-upstream-fair)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/nicholaschiasson/ngx_upstream_jdomain.git /usr/src/nginx/modules/ngx_upstream_jdomain || \
    (echo "克隆ngx_upstream_jdomain失败，重试..." && git clone --depth 1 --branch master https://github.com/nicholaschiasson/ngx_upstream_jdomain.git /usr/src/nginx/modules/ngx_upstream_jdomain)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_zstd_module.git /usr/src/nginx/modules/zstd-nginx || \
    (echo "克隆zstd-nginx失败，重试..." && git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_zstd_module.git /usr/src/nginx/modules/zstd-nginx)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/arut/nginx-rtmp-module.git /usr/src/nginx/modules/nginx-rtmp || \
    (echo "克隆nginx-rtmp失败，重试..." && git clone --depth 1 --branch master https://github.com/arut/nginx-rtmp-module.git /usr/src/nginx/modules/nginx-rtmp)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/yaoweibin/nginx_upstream_check_module.git /usr/src/nginx/modules/ngx_upstream_check || \
    (echo "克隆ngx_upstream_check失败，重试..." && git clone --depth 1 --branch master https://github.com/yaoweibin/nginx_upstream_check_module.git /usr/src/nginx/modules/ngx_upstream_check)

RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/replay/ngx_http_consistent_hash.git /usr/src/nginx/modules/ngx_upstream_consistent_hash || \
    (echo "克隆ngx_upstream_consistent_hash失败，重试..." && git clone --depth 1 --branch master https://github.com/replay/ngx_http_consistent_hash.git /usr/src/nginx/modules/ngx_upstream_consistent_hash)

# 应用upstream_check模块补丁（适配Nginx 1.29+）
RUN set -eux; \
    cd /usr/src/nginx/src; \
    wget -O upstream_check.patch https://ghproxy.net/https://raw.githubusercontent.com/yaoweibin/nginx_upstream_check_module/master/check_1.20.1+.patch; \
    patch -p1 < upstream_check.patch || echo "upstream_check补丁适配警告（非致命）"; \
    rm -f upstream_check.patch

# 编译zstd
RUN set -eux; \
    mkdir -p /usr/local/zstd-pic; \
    cd /tmp; \
    ZSTD_VERSION="1.5.7"; \
    wget -O zstd-${ZSTD_VERSION}.tar.gz https://github.com/facebook/zstd/archive/refs/tags/v${ZSTD_VERSION}.tar.gz; \
    tar -xzf zstd-${ZSTD_VERSION}.tar.gz; \
    cd zstd-${ZSTD_VERSION}; \
    make clean; \
    CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" make -j$(nproc) PREFIX=/usr/local/zstd-pic; \
    make PREFIX=/usr/local/zstd-pic install; \
    cd ..; \
    rm -rf zstd-${ZSTD_VERSION} zstd-${ZSTD_VERSION}.tar.gz

ENV ZSTD_INC=/usr/local/zstd-pic/include \
    ZSTD_LIB=/usr/local/zstd-pic/lib

# 编译Nginx（优化编译参数+修复LuaJIT链接+动态模块）
WORKDIR /usr/src/nginx/src
RUN set -eux; \
    ./configure \
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
        --with-threads \
        --with-file-aio \
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
        --with-cc-opt="-O2 -I${LUAJIT_INC} -I${ZSTD_INC} -I/usr/include" \
        --with-ld-opt="-L${LUAJIT_LIB} -L${ZSTD_LIB} -Wl,-rpath,${LUAJIT_LIB}:${ZSTD_LIB} -lzstd -Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now" \
        --add-dynamic-module=../modules/njs/nginx \
        --add-dynamic-module=../modules/ngx_devel_kit \
        --add-dynamic-module=../modules/ngx_dynamic_healthcheck \
        --add-dynamic-module=../modules/ngx_dynamic_upstream \
        --add-dynamic-module=../modules/traffic-accounting \
        --add-dynamic-module=../modules/array-var \
        --add-dynamic-module=../modules/nginx-auth-jwt \
        --add-dynamic-module=../modules/ngx_brotli \
        --add-dynamic-module=../modules/ngx_cache_purge \
        --add-dynamic-module=../modules/nginx_cookie_flag \
        --add-dynamic-module=../modules/nginx-dav-ext \
        --add-dynamic-module=../modules/echo \
        --add-dynamic-module=../modules/encrypted-session \
        --add-dynamic-module=../modules/ngx-fancyindex \
        --add-dynamic-module=../modules/ngx_http_geoip2_module \
        --add-dynamic-module=../modules/headers-more \
        --add-dynamic-module=../modules/nginx-keyval \
        --add-dynamic-module=../modules/nginx-log-zmq \
        --add-dynamic-module=../modules/lua-nginx \
        --add-dynamic-module=../modules/lua-upstream \
        --add-dynamic-module=../modules/naxsi/naxsi_src \
        --add-dynamic-module=../modules/nchan \
        --add-dynamic-module=../modules/redis2 \
        --add-dynamic-module=../modules/set-misc \
        --add-dynamic-module=../modules/ngx_slowfs_cache \
        --add-dynamic-module=../modules/nginx-upload \
        --add-dynamic-module=../modules/nginx-upload-progress \
        --add-dynamic-module=../modules/nginx-upstream-fair \
        --add-dynamic-module=../modules/ngx_upstream_jdomain \
        --add-dynamic-module=../modules/zstd-nginx \
        --add-dynamic-module=../modules/nginx-rtmp \
        --add-dynamic-module=../modules/ngx_upstream_check \
        --add-dynamic-module=../modules/ngx_upstream_consistent_hash; \
    make; \
    make install; \
    /usr/sbin/nginx -V; \
    make clean && rm -rf /etc/nginx/modules-enabled/*

RUN cd /etc/nginx/modules-available \
    && for module in /usr/lib/nginx/modules/*.so; do \
        module_name=$(basename $module .so); \
        echo "load_module $module;" > $module_name.load; \
    done

# 运行阶段：精简镜像（仅保留运行时依赖）
FROM debian:bookworm-slim AS nginx-run

# 重新声明需要的ARG（继承全局默认值，允许覆盖）
ARG NGINX_VERSION

LABEL maintainer="liubei66 <1967780821@qq.com>"
LABEL description="Nginx ${NGINX_VERSION} with custom modules (Alibaba Cloud Mirror)"

# 配置阿里云源+安装运行时依赖（恢复所有调试工具）
RUN set -eux; \
    rm -f /etc/apt/sources.list.d/* && echo "deb http://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list; \
    echo "deb http://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    echo "deb http://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https && \
    update-ca-certificates; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        libpcre3 zlib1g libssl3 libxslt1.1 libgd3 libgeoip1 libperl5.36 \
        libbrotli1 libzmq5 liblua5.1-0 libyaml-0-2 libxml2 libcurl3-gnutls \
        libjansson4 libmagic1 libtar0 libmaxminddb0 curl \
        iproute2 procps lsof dnsutils net-tools less jq \
        vim-tiny wget htop tcpdump strace rsync telnet; \
    rm -rf /var/lib/apt/lists/* ; \
    groupadd -r nginx && useradd -r -g nginx -s /sbin/nologin -d /var/lib/nginx nginx; \
    mkdir -p \
        /var/lib/nginx/tmp/{client_body,proxy,fastcgi,uwsgi,scgi} \
        /run/nginx \
        /etc/nginx/conf.d \
        /var/log/nginx; \
    chown -R nginx:nginx /var/lib/nginx /run/nginx /var/log/nginx; \
    chmod -R 755 /var/lib/nginx /run/nginx /var/log/nginx

# 从构建阶段复制编译产物
COPY --from=nginx-build /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-build /usr/lib/nginx /usr/lib/nginx
COPY --from=nginx-build /etc/nginx /etc/nginx
COPY --from=nginx-build /var/lib/nginx /var/lib/nginx
COPY --from=nginx-build /usr/local/lib /usr/local/lib
COPY --from=nginx-build /etc/ld.so.conf.d/luajit.conf /etc/ld.so.conf.d/

# 暴露端口
EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
