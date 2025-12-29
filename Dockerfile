# 定义全局版本与路径参数常量
ARG NGINX_VERSION=1.29.4
ARG NJS_VERSION=0.9.4
ARG PCRE2_VERSION=10.47
ARG JEMALLOC_VERSION=5.3.0
ARG ZSTD_VERSION=1.5.7

ARG BORINGSSL_SRC_DIR=/usr/src/boringssl
ARG MODULE_BASE_DIR=/src/modules
ARG NGINX_SRC_DIR=/src/nginx
ARG NGX_TLS_DYN_SIZE=nginx__dynamic_tls_records_1.29.2+.patch
ARG LUAJIT_VERSION=2.1-20250826
ARG LUAJIT_INC=/usr/local/include/luajit-2.1
ARG LUAJIT_LIB=/usr/local/lib

# 构建阶段：基于Alpine编译Nginx及所有依赖模块
FROM alpine:latest AS nginx-build
ARG NGINX_VERSION
ARG NJS_VERSION
ARG LUAJIT_VERSION
ARG PCRE2_VERSION
ARG JEMALLOC_VERSION
ARG ZSTD_VERSION
ARG BORINGSSL_SRC_DIR
ARG MODULE_BASE_DIR
ARG NGINX_SRC_DIR
ARG NGX_TLS_DYN_SIZE
ARG LUAJIT_INC
ARG LUAJIT_LIB

# 配置编译环境变量，指定依赖路径与并发编译参数
ENV LUAJIT_INC=${LUAJIT_INC} \
    LUAJIT_LIB=${LUAJIT_LIB} \
    LD_LIBRARY_PATH=${LUAJIT_LIB}:/usr/local/lib:/usr/local/zstd-pic/lib \
    MAKEFLAGS="-j$(nproc)" \
    CFLAGS="-fPIC -Os" \
    CXXFLAGS="-fPIC -Os"

# 设置编译工作根目录
WORKDIR /src

# 安装编译所需系统依赖与工具链
RUN set -eux; \
    apk add --no-cache \
        ca-certificates build-base patch cmake git libtool autoconf automake ninja \
        zlib-dev pcre2-dev linux-headers libxml2-dev libxslt-dev perl-dev \
        curl-dev geoip-dev libmaxminddb-dev libatomic_ops-dev libunwind-dev \
        brotli-dev zeromq-dev yaml-dev gd-dev openssl-dev luajit-dev jansson-dev \
        file-dev libfuzzy2-dev go wget tar gzip xz; \
    mkdir -p ${MODULE_BASE_DIR}

# 编译安装BoringSSL加密库，提供HTTPS/TLS/HTTP3加密能力
RUN set -eux; \
    git clone --depth 1 --recursive --branch main https://boringssl.googlesource.com/boringssl ${BORINGSSL_SRC_DIR} && \
    cd ${BORINGSSL_SRC_DIR} && \
    cmake -GNinja -B build -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release && \
    ninja -C build -j$(nproc) && \
    mkdir -p ${BORINGSSL_SRC_DIR}/.openssl/lib && \
    ln -s ${BORINGSSL_SRC_DIR}/include ${BORINGSSL_SRC_DIR}/.openssl/include && \
    cp ${BORINGSSL_SRC_DIR}/build/libcrypto.a ${BORINGSSL_SRC_DIR}/.openssl/lib/ && \
    cp ${BORINGSSL_SRC_DIR}/build/libssl.a ${BORINGSSL_SRC_DIR}/.openssl/lib/

# 编译安装LuaJIT引擎，为Lua模块提供高效运行环境
RUN set -eux; \
    LUAJIT_TAR="LuaJIT-${LUAJIT_VERSION}.tar.gz"; \
    wget -O ${LUAJIT_TAR} https://github.com/openresty/luajit2/archive/refs/tags/v${LUAJIT_VERSION}.tar.gz && \
    tar -xzf ${LUAJIT_TAR} -C ${MODULE_BASE_DIR} && \
    mv ${MODULE_BASE_DIR}/luajit2-${LUAJIT_VERSION} ${MODULE_BASE_DIR}/luajit && \
    cd ${MODULE_BASE_DIR}/luajit && \
    make PREFIX=/usr/local install && \
    cd /src && rm -rf ${LUAJIT_TAR} ${MODULE_BASE_DIR}/luajit

# 编译安装PCRE2正则库，启用JIT/多字符集/Unicode支持
RUN set -eux; \
    cd /tmp && \
    wget -O pcre2-${PCRE2_VERSION}.tar.gz https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz && \
    tar -xzf pcre2-${PCRE2_VERSION}.tar.gz && cd pcre2-${PCRE2_VERSION} && \
    ./configure --enable-jit --enable-pcre2-16 --enable-pcre2-32 --enable-unicode --with-pic && \
    make -j$(nproc) && make install && ldconfig && \
    cd .. && rm -rf pcre2-${PCRE2_VERSION} pcre2-${PCRE2_VERSION}.tar.gz

# 编译安装Jemalloc内存分配器，优化内存管理与性能
RUN set -eux; \
    cd /tmp && \
    wget -O jemalloc-${JEMALLOC_VERSION}.tar.gz https://github.com/jemalloc/jemalloc/archive/refs/tags/${JEMALLOC_VERSION}.tar.gz && \
    tar -zxf jemalloc-${JEMALLOC_VERSION}.tar.gz && cd jemalloc-${JEMALLOC_VERSION} && \
    ./autogen.sh && ./configure --prefix=/usr/local --with-pic && \
    make -j$(nproc) && make install && ldconfig && \
    cd .. && rm -rf jemalloc-${JEMALLOC_VERSION} jemalloc-${JEMALLOC_VERSION}.tar.gz

# 编译安装ZSTD压缩库，启用fPIC编译适配动态链接
RUN set -eux; \
    mkdir -p /usr/local/zstd-pic && cd /tmp && \
    wget -O zstd-${ZSTD_VERSION}.tar.gz https://github.com/facebook/zstd/archive/refs/tags/v${ZSTD_VERSION}.tar.gz && \
    tar -zxf zstd-${ZSTD_VERSION}.tar.gz && cd zstd-${ZSTD_VERSION} && \
    make clean && CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" make -j$(nproc) PREFIX=/usr/local/zstd-pic && \
    make PREFIX=/usr/local/zstd-pic install && \
    cd .. && rm -rf zstd-${ZSTD_VERSION} zstd-${ZSTD_VERSION}.tar.gz

# 下载解压NJS模块，为Nginx提供JavaScript扩展能力
RUN set -eux; \
    NJS_TAR="${MODULE_BASE_DIR}/njs-${NJS_VERSION}.tar.gz"; \
    wget -O ${NJS_TAR} https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz; \
    tar -zxf ${NJS_TAR} -C ${MODULE_BASE_DIR}; \
    mv ${MODULE_BASE_DIR}/njs-${NJS_VERSION} ${MODULE_BASE_DIR}/njs; \
    rm -f ${NJS_TAR}; \
    [ -d "${MODULE_BASE_DIR}/njs/nginx" ] || (echo "njs模块目录异常，构建失败" && exit 1)

# 编译安装QuickJS引擎，提供轻量级JS执行环境
RUN set -eux; \
    git clone https://github.com/bellard/quickjs ${MODULE_BASE_DIR}/quickjs && \
    cd ${MODULE_BASE_DIR}/quickjs && CFLAGS='-fPIC' make libquickjs.a

# 下载Nginx源码并应用TLS动态记录补丁，优化TLS传输性能
RUN set -eux; \
    wget https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -O - | tar xzC /src && \
    mv /src/nginx-${NGINX_VERSION} /src/nginx && \
    wget -O ${NGINX_SRC_DIR}/dynamic_tls_records.patch https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/master/${NGX_TLS_DYN_SIZE} && \
    cd ${NGINX_SRC_DIR} && patch -p1 < dynamic_tls_records.patch

# 应用upstream_check模块补丁，修复编译兼容性
RUN set -eux; \
    cd ${NGINX_SRC_DIR}/src; \
    wget -O upstream_check.patch https://raw.githubusercontent.com/yaoweibin/nginx_upstream_check_module/master/check_1.20.1+.patch; \
    patch -p1 < upstream_check.patch || echo "upstream_check补丁适配警告"; \
    rm -f upstream_check.patch

# 克隆所有第三方扩展模块，扩展Nginx核心功能
RUN set -eux; mkdir -p ${MODULE_BASE_DIR} && \
    git clone --depth 1 --branch master https://github.com/vision5/ngx_devel_kit.git ${MODULE_BASE_DIR}/ngx_devel_kit && \
    git clone --depth 1 --branch master https://github.com/ZigzagAK/ngx_dynamic_upstream.git ${MODULE_BASE_DIR}/ngx_dynamic_upstream && \
    git clone --depth 1 --branch master https://github.com/Lax/traffic-accounting-nginx-module.git ${MODULE_BASE_DIR}/traffic-accounting && \
    git clone --depth 1 --branch master https://github.com/openresty/array-var-nginx-module.git ${MODULE_BASE_DIR}/array-var && \
    git clone --depth 1 --branch master https://github.com/google/ngx_brotli.git ${MODULE_BASE_DIR}/ngx_brotli && \
    git clone --depth 1 --branch master https://github.com/nginx-modules/ngx_cache_purge.git ${MODULE_BASE_DIR}/ngx_cache_purge && \
    git clone --depth 1 --branch master https://github.com/AirisX/nginx_cookie_flag_module.git ${MODULE_BASE_DIR}/nginx_cookie_flag && \
    git clone --depth 1 --branch master https://github.com/arut/nginx-dav-ext-module.git ${MODULE_BASE_DIR}/nginx-dav-ext && \
    git clone --depth 1 --branch master https://github.com/openresty/echo-nginx-module.git ${MODULE_BASE_DIR}/echo && \
    git clone --depth 1 --branch master https://github.com/openresty/encrypted-session-nginx-module.git ${MODULE_BASE_DIR}/encrypted-session && \
    git clone --depth 1 --branch master https://github.com/openresty/headers-more-nginx-module.git ${MODULE_BASE_DIR}/headers-more && \
    git clone --depth 1 --branch master https://github.com/openresty/lua-nginx-module.git ${MODULE_BASE_DIR}/lua-nginx && \
    git clone --depth 1 --branch master https://github.com/openresty/lua-upstream-nginx-module.git ${MODULE_BASE_DIR}/lua-upstream && \
    git clone --depth 1 --branch master https://github.com/openresty/redis2-nginx-module.git ${MODULE_BASE_DIR}/redis2 && \
    git clone --depth 1 --branch master https://github.com/openresty/set-misc-nginx-module.git ${MODULE_BASE_DIR}/set-misc && \
    git clone --depth 1 --branch master https://github.com/aperezdc/ngx-fancyindex.git ${MODULE_BASE_DIR}/ngx-fancyindex && \
    git clone --depth 1 --branch master https://github.com/leev/ngx_http_geoip2_module.git ${MODULE_BASE_DIR}/ngx_http_geoip2_module && \
    git clone --depth 1 --branch main https://github.com/kjdev/nginx-keyval.git ${MODULE_BASE_DIR}/nginx-keyval && \
    git clone --depth 1 --branch master https://github.com/nginx-modules/nginx-log-zmq.git ${MODULE_BASE_DIR}/nginx-log-zmq && \
    git clone --depth 1 --branch master https://github.com/nbs-system/naxsi.git ${MODULE_BASE_DIR}/naxsi && \
    git clone --depth 1 --branch master https://github.com/FRiCKLE/ngx_slowfs_cache.git ${MODULE_BASE_DIR}/ngx_slowfs_cache && \
    git clone --depth 1 --branch master https://github.com/fdintino/nginx-upload-module.git ${MODULE_BASE_DIR}/nginx-upload && \
    git clone --depth 1 --branch master https://github.com/masterzen/nginx-upload-progress-module.git ${MODULE_BASE_DIR}/nginx-upload-progress && \
    git clone --depth 1 --branch master https://github.com/runenyUnidex/nginx-upstream-fair.git ${MODULE_BASE_DIR}/nginx-upstream-fair && \
    git clone --depth 1 --branch master https://github.com/RekGRpth/ngx_upstream_jdomain.git ${MODULE_BASE_DIR}/ngx_upstream_jdomain && \
    git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_zstd_module.git ${MODULE_BASE_DIR}/zstd-nginx && \
    git clone --depth 1 --branch master https://github.com/arut/nginx-rtmp-module.git ${MODULE_BASE_DIR}/nginx-rtmp && \
    git clone --depth 1 --branch master https://github.com/gi0baro/nginx-upstream-dynamic-servers.git ${MODULE_BASE_DIR}/nginx-upstream-dynamic-servers && \
    git clone --depth 1 --branch master https://github.com/HanadaLee/ngx_http_upstream_check_module.git ${MODULE_BASE_DIR}/ngx_upstream_check && \
    cd ${MODULE_BASE_DIR}/ngx_brotli && git submodule update --init && cd -

# 配置并编译Nginx，集成所有核心模块与第三方扩展模块
RUN set -eux; \
    cd ${NGINX_SRC_DIR} && \
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
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-threads \
        --with-file-aio \
        --with-pcre-jit \
        --without-poll_module \
        --without-select_module \
        --with-openssl="${BORINGSSL_SRC_DIR}" \
        --with-cc-opt="-I${LUAJIT_INC} -I${BORINGSSL_SRC_DIR}/.openssl/include -I/usr/local/zstd-pic/include -I/usr/local/include -I${MODULE_BASE_DIR}/quickjs -Wno-error -Wno-deprecated-declarations -fPIC" \
        --with-ld-opt="-L${LUAJIT_LIB} -L${BORINGSSL_SRC_DIR}/.openssl/lib -L/usr/local/lib -L/usr/local/zstd-pic/lib -L${MODULE_BASE_DIR}/quickjs -Wl,-rpath,${LUAJIT_LIB}:/usr/local/lib:/usr/local/zstd-pic/lib -lssl -lcrypto -lstdc++ -lzstd -lquickjs -lluajit-5.1 -lz -lpcre2-8 -ljemalloc -lpthread" \
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
        --with-mail=dynamic \
        --with-mail_ssl_module \
        --with-stream=dynamic \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_geoip_module=dynamic \
        --with-stream_ssl_preread_module \
        --add-dynamic-module=${MODULE_BASE_DIR}/njs/nginx \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_devel_kit \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_dynamic_upstream \
        --add-dynamic-module=${MODULE_BASE_DIR}/traffic-accounting \
        --add-dynamic-module=${MODULE_BASE_DIR}/array-var \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_brotli \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_cache_purge \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx_cookie_flag \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-dav-ext \
        --add-dynamic-module=${MODULE_BASE_DIR}/echo \
        --add-dynamic-module=${MODULE_BASE_DIR}/encrypted-session \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx-fancyindex \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_http_geoip2_module \
        --add-dynamic-module=${MODULE_BASE_DIR}/headers-more \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-keyval \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-log-zmq \
        --add-dynamic-module=${MODULE_BASE_DIR}/lua-nginx \
        --add-dynamic-module=${MODULE_BASE_DIR}/lua-upstream \
        --add-dynamic-module=${MODULE_BASE_DIR}/naxsi/naxsi_src \
        --add-dynamic-module=${MODULE_BASE_DIR}/redis2 \
        --add-dynamic-module=${MODULE_BASE_DIR}/set-misc \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_slowfs_cache \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-upload \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-upload-progress \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-upstream-fair \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_upstream_jdomain \
        --add-dynamic-module=${MODULE_BASE_DIR}/zstd-nginx \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-rtmp \
        --add-dynamic-module=${MODULE_BASE_DIR}/nginx-upstream-dynamic-servers \
        --add-dynamic-module=${MODULE_BASE_DIR}/ngx_upstream_check && \
    touch ${BORINGSSL_SRC_DIR}/include/openssl/ssl.h && \
    make -j "$(nproc)" && make -j "$(nproc)" install && \
    make clean && rm -rf ${NGINX_SRC_DIR}/*.patch && \
    strip -s /usr/sbin/nginx && strip -s /usr/lib/nginx/modules/*.so && \
    for module in /usr/lib/nginx/modules/*.so; do \
         module_name=$(basename $module .so); \
         echo "load_module $module;" >$module_name.load; \
    done

# 运行阶段：构建精简Alpine生产镜像
FROM alpine:latest AS nginx-run
ARG NGINX_VERSION

# 设置镜像元信息标识
LABEL maintainer="liubei66 <1967780821@qq.com>"
LABEL description="Nginx ${NGINX_VERSION} with BoringSSL + custom modules + PCRE2 JIT + Jemalloc + HTTP3/QUIC + TLS Dynamic Size (Alpine)"

# 安装运行时依赖，配置用户与目录权限
RUN set -eux; \
    apk add --no-cache \
        ca-certificates zlib pcre2 libxslt gd geoip libmaxminddb brotli zeromq luajit yaml \
        libcurl jansson file libmagic jemalloc libstdc++ libatomic iproute2 procps curl lsof \
        bind-tools net-tools less jq vim wget htop; \
    update-ca-certificates; \
    addgroup -g 1001 -S nginx && adduser -S -D -H -u 1001 -h /var/lib/nginx -s /sbin/nologin -G nginx nginx; \
    mkdir -p /var/lib/nginx/tmp/client_body /var/lib/nginx/tmp/proxy /var/lib/nginx/tmp/fastcgi \
        /var/lib/nginx/tmp/uwsgi /var/lib/nginx/tmp/scgi /run/nginx /etc/nginx/conf.d /var/log/nginx; \
    chown -R nginx:nginx /var/lib/nginx /run/nginx /var/log/nginx; \
    chmod -R 755 /var/lib/nginx /run/nginx /var/log/nginx


# 从编译阶段拷贝Nginx产物与依赖库
COPY --from=nginx-build /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-build /usr/lib/nginx /usr/lib/nginx
COPY --from=nginx-build /etc/nginx /etc/nginx
COPY --from=nginx-build /var/lib/nginx /var/lib/nginx
COPY --from=nginx-build /usr/local /usr/local


# 暴露服务端口，含TCP/UDP适配HTTP3
EXPOSE 80 443 443/udp

# 前台启动Nginx服务，保证容器常驻
CMD ["sh", "-c", "nginx -g 'daemon off;'"]
