# 全局构建版本与路径参数定义
ARG NGINX_VERSION=1.29.4
ARG NJS_VERSION=0.9.4

# Nginx源码根目录，统一管理所有源码相关文件
ARG NGINX_SRC_DIR=/usr/src/nginx
# Nginx模块存放目录，基于源码根目录关联定义
ARG NGINX_MODULES_DIR=${NGINX_SRC_DIR}/modules

ARG PCRE2_VERSION=10.47
ARG JEMALLOC_VERSION=5.3.0
ARG ZSTD_VERSION=1.5.7
ARG LUAJIT_VERSION=2.1-20250826

ARG LUAJIT_INC=/usr/local/include/luajit-2.1
ARG LUAJIT_LIB=/usr/local/lib
ARG OPENSSL_VERSION=3.0.15-quic1
ARG OPENSSL_SRC_DIR=/usr/src/openssl
# TLS动态记录补丁版本，统一管理
ARG NGX_TLS_DYN_SIZE=nginx__dynamic_tls_records_1.29.2+.patch

# 构建阶段：编译Nginx及所有依赖组件与模块
FROM debian:bookworm-slim AS nginx-build
ARG NGINX_VERSION
ARG NJS_VERSION
ARG LUAJIT_VERSION
ARG LUAJIT_INC
ARG LUAJIT_LIB
ARG OPENSSL_VERSION
ARG OPENSSL_SRC_DIR
ARG PCRE2_VERSION
ARG JEMALLOC_VERSION
ARG ZSTD_VERSION
ARG NGINX_SRC_DIR
ARG NGINX_MODULES_DIR
ARG NGX_TLS_DYN_SIZE

# 配置编译环境变量
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/pkgconfig \
    GIT_SSL_NO_VERIFY=1 \
    MAKEFLAGS="-j$(nproc)"

# 安装编译依赖包，创建工作目录，配置系统库加载路径
RUN set -eux; \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https \
    wget git gcc g++ make patch unzip libtool autoconf \
    libpcre3-dev zlib1g-dev libgeoip-dev libperl-dev \
    libbrotli-dev libzmq3-dev liblua5.1-dev libyaml-dev libxml2-dev \
    libcurl4-openssl-dev libjansson-dev libmagic-dev libtar-dev libmaxminddb-dev \
    libxslt-dev libgd-dev libmail-dkim-perl libjwt-dev \
    libnginx-mod-http-dav-ext libpcre2-dev libjemalloc-dev binutils; \
    apt-get purge -y libssl-dev; \
    update-ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p ${NGINX_SRC_DIR}/src ${NGINX_MODULES_DIR} ${OPENSSL_SRC_DIR} /usr/local/lib; \
    chmod -R 755 ${NGINX_SRC_DIR} ${NGINX_MODULES_DIR} ${OPENSSL_SRC_DIR} /usr/local/lib; \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/global-libs.conf && ldconfig

# 下载、解压并编译ZSTD库
RUN set -eux; \
    cd /tmp; \
    wget -O zstd-${ZSTD_VERSION}.tar.gz https://github.com/facebook/zstd/archive/refs/tags/v${ZSTD_VERSION}.tar.gz; \
    tar -zxf zstd-${ZSTD_VERSION}.tar.gz; \
    cd zstd-${ZSTD_VERSION}; \
    make clean; \
    CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" make -j$(nproc); \
    make PREFIX=/usr/local install; \
    ldconfig; \
    rm -rf /tmp/zstd-${ZSTD_VERSION} /tmp/zstd-${ZSTD_VERSION}.tar.gz

# 下载并解压NJS模块
RUN set -eux; \
    NJS_TAR="${NGINX_SRC_DIR}/njs-${NJS_VERSION}.tar.gz"; \
    wget -O ${NJS_TAR} https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz; \
    tar -zxf ${NJS_TAR} -C ${NGINX_MODULES_DIR}; \
    mv ${NGINX_MODULES_DIR}/njs-${NJS_VERSION} ${NGINX_MODULES_DIR}/njs; \
    rm -f ${NJS_TAR}; \
    [ -d "${NGINX_MODULES_DIR}/njs/nginx" ] || (echo "njs模块目录异常，构建失败" && exit 1)

# 下载、解压并安装LuaJIT
RUN set -eux; \
    LUAJIT_TAR="LuaJIT-${LUAJIT_VERSION}.tar.gz"; \
    LUAJIT_URL="https://github.com/openresty/luajit2/archive/refs/tags/v${LUAJIT_VERSION}.tar.gz"; \
    wget -O ${NGINX_SRC_DIR}/${LUAJIT_TAR} ${LUAJIT_URL}; \
    tar -zxf ${NGINX_SRC_DIR}/${LUAJIT_TAR} -C ${NGINX_MODULES_DIR}; \
    mv ${NGINX_MODULES_DIR}/luajit2-${LUAJIT_VERSION} ${NGINX_MODULES_DIR}/luajit; \
    cd ${NGINX_MODULES_DIR}/luajit; \
    make PREFIX=/usr/local install; \
    ldconfig; \
    rm -rf ${NGINX_SRC_DIR}/${LUAJIT_TAR}

# 下载、解压并编译PCRE2库
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

# 下载、解压并编译Jemalloc库
RUN set -eux; \
    cd /tmp; \
    wget -O jemalloc-${JEMALLOC_VERSION}.tar.gz https://github.com/jemalloc/jemalloc/archive/refs/tags/${JEMALLOC_VERSION}.tar.gz; \
    tar -zxf jemalloc-${JEMALLOC_VERSION}.tar.gz; \
    cd jemalloc-${JEMALLOC_VERSION}; \
    ./autogen.sh; \
    ./configure --prefix=/usr/local --with-pic; \
    make -j$(nproc); \
    make install; \
    ldconfig; \
    rm -rf /tmp/jemalloc-${JEMALLOC_VERSION} /tmp/jemalloc-${JEMALLOC_VERSION}.tar.gz

# 下载、编译并部署QuickJS引擎
RUN set -eux; \
    git clone https://github.com/bellard/quickjs ${NGINX_MODULES_DIR}/quickjs; \
    cd ${NGINX_MODULES_DIR}/quickjs; \
    CFLAGS='-fPIC' make libquickjs.a

# 下载并编译OpenSSL
RUN set -eux; \
    OPENSSL_URL="https://github.com/quictls/openssl/archive/refs/tags/openssl-${OPENSSL_VERSION}.tar.gz"; \
    wget -O /usr/src/openssl-${OPENSSL_VERSION}.tar.gz ${OPENSSL_URL}; \
    tar -zxf /usr/src/openssl-${OPENSSL_VERSION}.tar.gz -C ${OPENSSL_SRC_DIR} --strip-components=1; \
    rm -f /usr/src/openssl-${OPENSSL_VERSION}.tar.gz; \
    cd ${OPENSSL_SRC_DIR}; \
    ./Configure no-shared zlib -O3 enable-tls1_3 enable-ktls enable-quic linux-x86_64; \
    make -j$(nproc)

# 下载并解压Nginx主源码包
RUN set -eux; \
    wget -O ${NGINX_SRC_DIR}/nginx-${NGINX_VERSION}.tar.gz https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz; \
    tar -zxf ${NGINX_SRC_DIR}/nginx-${NGINX_VERSION}.tar.gz -C ${NGINX_SRC_DIR}/src --strip-components=1; \
    rm -f ${NGINX_SRC_DIR}/nginx-${NGINX_VERSION}.tar.gz

# 下载并应用TLS动态记录补丁
RUN set -eux; \
    wget -O ${NGINX_SRC_DIR}/dynamic_tls_records.patch https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/master/${NGX_TLS_DYN_SIZE}; \
    cd ${NGINX_SRC_DIR}/src && patch -p1 < ${NGINX_SRC_DIR}/dynamic_tls_records.patch; \
    rm -f ${NGINX_SRC_DIR}/dynamic_tls_records.patch

# 下载并应用upstream_check模块补丁
RUN set -eux; \
    cd ${NGINX_SRC_DIR}/src; \
    wget -O upstream_check.patch https://raw.githubusercontent.com/yaoweibin/nginx_upstream_check_module/master/check_1.20.1+.patch; \
    patch -p1 < upstream_check.patch || echo "upstream_check补丁适配警告"; \
    rm -f upstream_check.patch

# 批量克隆Nginx第三方模块，初始化子模块并清理缓存
RUN set -eux; \
    git_clone() { \
        local repo_url="$1"; local target_dir="$2"; local branch="$3"; \
        git clone --depth 1 --branch "${branch}" "${repo_url}" "${target_dir}" || git clone --depth 1 --branch "${branch}" "${repo_url}" "${target_dir}"; \
    }; \
    git_clone https://github.com/vision5/ngx_devel_kit.git ${NGINX_MODULES_DIR}/ngx_devel_kit master; \
    git_clone https://github.com/vozlt/nginx-module-vts.git ${NGINX_MODULES_DIR}/nginx-module-vts master; \
    git_clone https://github.com/Lax/traffic-accounting-nginx-module.git ${NGINX_MODULES_DIR}/traffic-accounting master; \
    git_clone https://github.com/openresty/array-var-nginx-module.git ${NGINX_MODULES_DIR}/array-var master; \
    git_clone https://github.com/nginx-modules/ngx_cache_purge.git ${NGINX_MODULES_DIR}/ngx_cache_purge master; \
    git_clone https://github.com/google/ngx_brotli.git ${NGINX_MODULES_DIR}/ngx_brotli master; \
    git_clone https://github.com/AirisX/nginx_cookie_flag_module.git ${NGINX_MODULES_DIR}/nginx_cookie_flag master; \
    git_clone https://github.com/arut/nginx-dav-ext-module.git ${NGINX_MODULES_DIR}/nginx-dav-ext master; \
    git_clone https://github.com/openresty/echo-nginx-module.git ${NGINX_MODULES_DIR}/echo master; \
    git_clone https://github.com/openresty/encrypted-session-nginx-module.git ${NGINX_MODULES_DIR}/encrypted-session master; \
    git_clone https://github.com/openresty/headers-more-nginx-module.git ${NGINX_MODULES_DIR}/headers-more master; \
    git_clone https://github.com/openresty/lua-nginx-module.git ${NGINX_MODULES_DIR}/lua-nginx master; \
    git_clone https://github.com/openresty/lua-upstream-nginx-module.git ${NGINX_MODULES_DIR}/lua-upstream master; \
    git_clone https://github.com/openresty/redis2-nginx-module.git ${NGINX_MODULES_DIR}/redis2 master; \
    git_clone https://github.com/openresty/set-misc-nginx-module.git ${NGINX_MODULES_DIR}/set-misc master; \
    git_clone https://github.com/aperezdc/ngx-fancyindex.git ${NGINX_MODULES_DIR}/ngx-fancyindex master; \
    git_clone https://github.com/leev/ngx_http_geoip2_module.git ${NGINX_MODULES_DIR}/ngx_http_geoip2_module master; \
    git_clone https://github.com/kjdev/nginx-keyval.git ${NGINX_MODULES_DIR}/nginx-keyval main; \
    git_clone https://github.com/nginx-modules/nginx-log-zmq.git ${NGINX_MODULES_DIR}/nginx-log-zmq master; \
    git_clone https://github.com/nbs-system/naxsi.git ${NGINX_MODULES_DIR}/naxsi master; \
    git_clone https://github.com/slact/nchan.git ${NGINX_MODULES_DIR}/nchan master; \
    git_clone https://github.com/fdintino/nginx-upload-module.git ${NGINX_MODULES_DIR}/nginx-upload master; \
    git_clone https://github.com/masterzen/nginx-upload-progress-module.git ${NGINX_MODULES_DIR}/nginx-upload-progress master; \
    git_clone https://github.com/runenyUnidex/nginx-upstream-fair.git ${NGINX_MODULES_DIR}/nginx-upstream-fair master; \
    git_clone https://github.com/HanadaLee/ngx_http_zstd_module.git ${NGINX_MODULES_DIR}/zstd-nginx master; \
    git_clone https://github.com/arut/nginx-rtmp-module.git ${NGINX_MODULES_DIR}/nginx-rtmp master; \
    git_clone https://github.com/HanadaLee/ngx_http_upstream_check_module.git ${NGINX_MODULES_DIR}/ngx_upstream_check master; \
    cd ${NGINX_MODULES_DIR}/ngx_brotli && git submodule update --init;

# 配置、编译并安装Nginx
WORKDIR ${NGINX_SRC_DIR}/src
RUN set -eux; \
./configure \
  --prefix=/etc/nginx \
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
  --with-cc-opt="-O3 -flto -I${LUAJIT_INC} -I${NGINX_MODULES_DIR}/quickjs -I/usr/local/include -I${OPENSSL_SRC_DIR}/include -I/usr/include" \
  --with-ld-opt="-L${LUAJIT_LIB} -L/usr/local/lib -L${OPENSSL_SRC_DIR} -L${NGINX_MODULES_DIR}/quickjs -Wl,-rpath,/usr/local/lib -lzstd -lquickjs -lssl -lcrypto -lz -lpcre2-8 -ljemalloc -Wl,-Bsymbolic-functions -flto" \
  --add-dynamic-module=${NGINX_MODULES_DIR}/njs/nginx \
  --add-dynamic-module=${NGINX_MODULES_DIR}/ngx_devel_kit \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-module-vts \
  --add-dynamic-module=${NGINX_MODULES_DIR}/ngx_cache_purge \
  --add-dynamic-module=${NGINX_MODULES_DIR}/traffic-accounting \
  --add-dynamic-module=${NGINX_MODULES_DIR}/array-var \
  --add-dynamic-module=${NGINX_MODULES_DIR}/ngx_brotli \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx_cookie_flag \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-dav-ext \
  --add-dynamic-module=${NGINX_MODULES_DIR}/echo \
  --add-dynamic-module=${NGINX_MODULES_DIR}/encrypted-session \
  --add-dynamic-module=${NGINX_MODULES_DIR}/ngx-fancyindex \
  --add-dynamic-module=${NGINX_MODULES_DIR}/ngx_http_geoip2_module \
  --add-dynamic-module=${NGINX_MODULES_DIR}/headers-more \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-keyval \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-log-zmq \
  --add-dynamic-module=${NGINX_MODULES_DIR}/lua-nginx \
  --add-dynamic-module=${NGINX_MODULES_DIR}/lua-upstream \
  --add-dynamic-module=${NGINX_MODULES_DIR}/naxsi/naxsi_src \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nchan \
  --add-dynamic-module=${NGINX_MODULES_DIR}/redis2 \
  --add-dynamic-module=${NGINX_MODULES_DIR}/set-misc \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-upload \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-upload-progress \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-upstream-fair \
  --add-dynamic-module=${NGINX_MODULES_DIR}/zstd-nginx \
  --add-dynamic-module=${NGINX_MODULES_DIR}/nginx-rtmp \
  --add-dynamic-module=${NGINX_MODULES_DIR}/ngx_upstream_check; \
make -j$(nproc); \
make install; \
/usr/sbin/nginx -V; \
make clean && rm -rf /etc/nginx/modules-enabled/* ${OPENSSL_SRC_DIR}; \
strip -s /usr/sbin/nginx && strip -s /usr/lib/nginx/modules/*.so \
&& strip -s /usr/local/lib/*.so \
&& find /usr/lib /usr/local/lib -name "*.a" -delete \
&& find /usr/lib /usr/local/lib -name "*.la" -delete; \
cd /etc/nginx/modules-available \
&& for module in /usr/lib/nginx/modules/*.so; do \
  module_name=$(basename $module .so); \
  echo "load_module $module;" >$module_name.load; \
done

# 运行阶段：构建Nginx运行镜像
FROM debian:bookworm-slim AS nginx-run
ARG NGINX_VERSION
ARG OPENSSL_VERSION

# 设置镜像标签信息
LABEL maintainer="liubei66 <1967780821@qq.com>"
LABEL description="Nginx ${NGINX_VERSION} with OpenSSL ${OPENSSL_VERSION} + custom modules + PCRE2 JIT + Jemalloc + kTLS"

# 安装运行依赖，创建运行用户及目录
RUN set -eux; \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https libzmq5 \
        curl iproute2 procps lsof dnsutils net-tools less jq \
        vim wget htop tcpdump strace telnet; \
    update-ca-certificates; \
    rm -f /usr/lib/apt/sources.list.d/*; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    echo "deb https://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
    rm -rf /var/lib/apt/lists/* ; \
    groupadd -r nginx && useradd -r -g nginx -s /sbin/nologin -d /var/lib/nginx nginx; \
    mkdir -p /var/lib/nginx/tmp/client_body /var/lib/nginx/tmp/proxy /var/lib/nginx/tmp/fastcgi /var/lib/nginx/tmp/uwsgi /var/lib/nginx/tmp/scgi /run/nginx /etc/nginx/conf.d /var/log/nginx; \
    chown -R nginx:nginx /var/lib/nginx /run/nginx /var/log/nginx; \
    chmod -R 755 /var/lib/nginx /run/nginx /var/log/nginx;

# 复制编译产物至运行镜像
COPY --from=nginx-build /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-build /usr/lib/nginx /usr/lib/nginx
COPY --from=nginx-build /etc/nginx /etc/nginx
COPY --from=nginx-build /var/lib/nginx /var/lib/nginx
COPY --from=nginx-build /usr/local/lib /usr/local/lib

# 暴露服务端口
EXPOSE 80 443 443/udp

# 启动Nginx服务
CMD ["nginx", "-g", "daemon off;"]
