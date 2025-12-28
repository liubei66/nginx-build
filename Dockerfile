# 全局构建参数定义
ARG NGINX_VERSION=1.29.4
ARG NJS_VERSION=0.9.4
ARG LUAJIT_VERSION=2.1-20250826
ARG LUAJIT_TAR=LuaJIT-${LUAJIT_VERSION}.tar.gz
ARG LUAJIT_URL=https://github.com/openresty/luajit2/archive/refs/tags/v${LUAJIT_VERSION}.tar.gz
ARG LUAJIT_INC=/usr/local/include/luajit-2.1
ARG LUAJIT_LIB=/usr/local/lib
ARG ZSTD_INC=/usr/local/zstd-pic/include
ARG ZSTD_LIB=/usr/local/zstd-pic/lib
ARG BORINGSSL_SRC_DIR=/usr/src/boringssl
ARG PCRE2_VERSION=10.47
ARG JEMALLOC_VERSION=5.3.0
ARG NGX_TLS_DYN_SIZE=nginx__dynamic_tls_records_1.29.2+.patch

# 构建阶段：编译Nginx及依赖模块
FROM debian:bookworm-slim AS nginx-build

# 继承全局构建参数
ARG NGINX_VERSION
ARG NJS_VERSION
ARG LUAJIT_VERSION
ARG LUAJIT_TAR
ARG LUAJIT_URL
ARG LUAJIT_INC
ARG LUAJIT_LIB
ARG ZSTD_INC
ARG ZSTD_LIB
ARG BORINGSSL_SRC_DIR
ARG PCRE2_VERSION
ARG JEMALLOC_VERSION
ARG NGX_TLS_DYN_SIZE

# 设置环境变量
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/pkgconfig \
    GIT_SSL_NO_VERIFY=1 \
    MAKEFLAGS="-j$(nproc)"

# 安装编译依赖并创建工作目录
RUN set -eux; \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https \
    wget git gcc g++ make patch unzip libtool autoconf cmake ninja-build \
    libpcre3-dev zlib1g-dev libxslt1-dev libgd-dev libgeoip-dev \
    libperl-dev libbrotli-dev libzmq3-dev liblua5.1-dev libyaml-dev libxml2-dev \
    libcurl4-openssl-dev libjansson-dev libmagic-dev libtar-dev libmaxminddb-dev \
    libxslt-dev libgd-dev libgeoip-dev libperl-dev libmail-dkim-perl libjwt-dev \
    libnginx-mod-http-dav-ext libpcre2-dev libjemalloc-dev libstdc++6; \
    apt-get purge -y libssl-dev; \
    update-ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /usr/src/nginx /usr/src/nginx/modules \
             ${BORINGSSL_SRC_DIR} && \
    chmod -R 755 /usr/src/nginx

# 编译安装BoringSSL（参照Alpine可编译版本，目录结构1:1适配）
RUN set -eux; \
    git clone --depth 1 --recursive --branch main https://boringssl.googlesource.com/boringssl ${BORINGSSL_SRC_DIR}; \
    cd ${BORINGSSL_SRC_DIR}; \
    cmake -GNinja -B build -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release; \
    ninja -C build; \
    mkdir -p .openssl/lib; \
    ln -sf ${BORINGSSL_SRC_DIR}/include .openssl/include; \
    cp build/libcrypto.a build/libssl.a .openssl/lib/; \
    rm -rf build

# 下载Nginx源码+TLS动态补丁+版本伪装+响应头修改（完整追加指定核心逻辑）
RUN set -eux; \
    wget https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -O - | tar xzC /usr/src/nginx; \
    mv /usr/src/nginx/nginx-${NGINX_VERSION} /usr/src/nginx/src; \
    wget https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/master/${NGX_TLS_DYN_SIZE} -O /usr/src/nginx/src/dynamic_tls_records.patch; \
    cd /usr/src/nginx/src && patch -p1 < dynamic_tls_records.patch

# 下载并解压njs模块
RUN set -eux; \
    NJS_TAR="/usr/src/nginx/njs-${NJS_VERSION}.tar.gz"; \
    wget -O ${NJS_TAR} https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz; \
    tar -zxf ${NJS_TAR} -C /usr/src/nginx/modules; \
    mv /usr/src/nginx/modules/njs-${NJS_VERSION} /usr/src/nginx/modules/njs; \
    rm -f ${NJS_TAR}; \
    [ -d "/usr/src/nginx/modules/njs/nginx" ] || (echo "njs模块目录异常，构建失败" && exit 1)

# 安装LuaJIT
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

# 编译安装PCRE2
RUN set -eux; \
    cd /tmp; \
    wget -O pcre2-${PCRE2_VERSION}.tar.gz https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz; \
    tar -zxf pcre2-${PCRE2_VERSION}.tar.gz; \
    cd pcre2-${PCRE2_VERSION}; \
    ./configure --prefix=/usr/local --enable-jit --enable-pcre2-16 --enable-pcre2-32 --enable-unicode --with-pic; \
    make -j$(nproc); \
    make install; \
    ldconfig; \
    rm -rf /tmp/pcre2-${PCRE2_VERSION} /tmp/pcre2-${PCRE2_VERSION}.tar.gz

# 编译安装Jemalloc
RUN set -eux; \
    cd /tmp; \
    wget -O jemalloc-${JEMALLOC_VERSION}.tar.gz https://github.com/jemalloc/jemalloc/archive/refs/tags/${JEMALLOC_VERSION}.tar.gz; \
    tar -zxf jemalloc-${JEMALLOC_VERSION}.tar.gz; \
    cd jemalloc-${JEMALLOC_VERSION}; \
    ./autogen.sh; \
    ./configure --prefix=/usr/local --with-pic; \
    make -j$(nproc); \
    make install; \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/jemalloc.conf; \
    ldconfig; \
    rm -rf /tmp/jemalloc-${JEMALLOC_VERSION} /tmp/jemalloc-${JEMALLOC_VERSION}.tar.gz

# 编译安装QuickJS
RUN set -eux; \
    git clone https://github.com/bellard/quickjs /usr/src/nginx/modules/quickjs; \
    cd /usr/src/nginx/modules/quickjs; \
    CFLAGS='-fPIC' make libquickjs.a; \
    echo "/usr/src/nginx/modules/quickjs" > /etc/ld.so.conf.d/quickjs.conf; \
    ldconfig

# 克隆ngx_devel_kit模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/vision5/ngx_devel_kit.git /usr/src/nginx/modules/ngx_devel_kit

# 克隆nginx-module-vts模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/vozlt/nginx-module-vts.git /usr/src/nginx/modules/nginx-module-vts

# 克隆ngx_dynamic_upstream模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/ZigzagAK/ngx_dynamic_upstream.git /usr/src/nginx/modules/ngx_dynamic_upstream

# 克隆traffic-accounting模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/Lax/traffic-accounting-nginx-module.git /usr/src/nginx/modules/traffic-accounting

# 克隆array-var模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/array-var-nginx-module.git /usr/src/nginx/modules/array-var

# 克隆ngx_brotli模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/google/ngx_brotli.git /usr/src/nginx/modules/ngx_brotli; \
    cd /usr/src/nginx/modules/ngx_brotli && git submodule update --init

# 克隆ngx_cache_purge模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/nginx-modules/ngx_cache_purge.git /usr/src/nginx/modules/ngx_cache_purge

# 克隆nginx_cookie_flag模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/AirisX/nginx_cookie_flag_module.git /usr/src/nginx/modules/nginx_cookie_flag

# 克隆nginx-dav-ext模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/arut/nginx-dav-ext-module.git /usr/src/nginx/modules/nginx-dav-ext

# 克隆echo模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/echo-nginx-module.git /usr/src/nginx/modules/echo

# 克隆encrypted-session模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/encrypted-session-nginx-module.git /usr/src/nginx/modules/encrypted-session

# 克隆headers-more模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/headers-more-nginx-module.git /usr/src/nginx/modules/headers-more

# 克隆lua-nginx模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/lua-nginx-module.git /usr/src/nginx/modules/lua-nginx

# 克隆lua-upstream模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/lua-upstream-nginx-module.git /usr/src/nginx/modules/lua-upstream

# 克隆redis2模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/redis2-nginx-module.git /usr/src/nginx/modules/redis2

# 克隆set-misc模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/openresty/set-misc-nginx-module.git /usr/src/nginx/modules/set-misc

# 克隆ngx-fancyindex模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/aperezdc/ngx-fancyindex.git /usr/src/nginx/modules/ngx-fancyindex

# 克隆ngx_http_geoip2_module模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/leev/ngx_http_geoip2_module.git /usr/src/nginx/modules/ngx_http_geoip2_module

# 克隆nginx-keyval模块
RUN set -eux; \
    git clone --depth 1 --branch main https://github.com/kjdev/nginx-keyval.git /usr/src/nginx/modules/nginx-keyval

# 克隆nginx-log-zmq模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/nginx-modules/nginx-log-zmq.git /usr/src/nginx/modules/nginx-log-zmq

# 克隆naxsi模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/nbs-system/naxsi.git /usr/src/nginx/modules/naxsi

# 克隆nchan模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/slact/nchan.git /usr/src/nginx/modules/nchan

# 克隆ngx_slowfs_cache模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/FRiCKLE/ngx_slowfs_cache.git /usr/src/nginx/modules/ngx_slowfs_cache

# 克隆nginx-upload模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/fdintino/nginx-upload-module.git /usr/src/nginx/modules/nginx-upload

# 克隆nginx-upload-progress模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/masterzen/nginx-upload-progress-module.git /usr/src/nginx/modules/nginx-upload-progress

# 克隆nginx-upstream-fair模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/runenyUnidex/nginx-upstream-fair.git /usr/src/nginx/modules/nginx-upstream-fair

# 克隆ngx_upstream_jdomain模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/RekGRpth/ngx_upstream_jdomain.git /usr/src/nginx/modules/ngx_upstream_jdomain

# 克隆zstd-nginx模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_zstd_module.git /usr/src/nginx/modules/zstd-nginx

# 克隆nginx-rtmp模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/arut/nginx-rtmp-module.git /usr/src/nginx/modules/nginx-rtmp

# 克隆nginx-upstream-dynamic-servers模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/gi0baro/nginx-upstream-dynamic-servers.git /usr/src/nginx/modules/nginx-upstream-dynamic-servers

# 克隆ngx_upstream_check模块
RUN set -eux; \
    git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_upstream_check_module.git /usr/src/nginx/modules/ngx_upstream_check

# 应用upstream_check模块补丁
RUN set -eux; \
    cd /usr/src/nginx/src; \
    wget -O upstream_check.patch https://raw.githubusercontent.com/yaoweibin/nginx_upstream_check_module/master/check_1.20.1+.patch; \
    patch -p1 < upstream_check.patch; \
    rm -f upstream_check.patch

# 编译安装zstd
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

# 编译Nginx并安装模块配置
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
  --with-compat \
  --with-threads \
  --with-file-aio \
  --with-libatomic \
  --with-pcre-jit \
  --without-poll_module \
  --without-select_module \
  --with-openssl=${BORINGSSL_SRC_DIR} \
  --with-cc-opt="-I${BORINGSSL_SRC_DIR}/.openssl/include -I${LUAJIT_INC} -I${ZSTD_INC} -I/usr/local/include -I/usr/src/nginx/modules/quickjs -Wno-error -Wno-deprecated-declarations -fPIC" \
  --with-ld-opt="-L${BORINGSSL_SRC_DIR}/.openssl/lib -L${LUAJIT_LIB} -L${ZSTD_LIB} -L/usr/src/nginx/modules/quickjs -L/usr/local/lib -Wl,-rpath,${LUAJIT_LIB}:${ZSTD_LIB}:/usr/local/lib -lssl -lcrypto -lstdc++ -lzstd -lquickjs -lz -lpcre2-8 -ljemalloc -lpthread -Wl,-Bsymbolic-functions" \
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
  --add-dynamic-module=../modules/njs/nginx \
  --add-dynamic-module=../modules/ngx_devel_kit \
  --add-dynamic-module=../modules/nginx-module-vts \
  --add-dynamic-module=../modules/ngx_dynamic_upstream \
  --add-dynamic-module=../modules/traffic-accounting \
  --add-dynamic-module=../modules/array-var \
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
  --add-dynamic-module=../modules/nginx-upstream-dynamic-servers \
  --add-dynamic-module=../modules/ngx_upstream_check; \
touch ${BORINGSSL_SRC_DIR}/.openssl/include/openssl/ssl.h; \
make -j$(nproc); \
make install; \
/usr/sbin/nginx -V; \
make clean && rm -rf /etc/nginx/modules-enabled/* ${BORINGSSL_SRC_DIR} && \
  cd /etc/nginx/modules-available \
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
        iproute2 procps lsof dnsutils net-tools less jq vim-tiny wget htop; \
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