#!/bin/sh
# vim:sw=2:ts=2:sts=2:et

set -eu

LC_ALL=C
ME=$(basename "$0")
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 定义nginx用户组及需授权的目录
NGINX_USER="nginx"
NGINX_GROUP="nginx"
TARGET_DIRS="/var/lib/nginx /run/nginx /var/log/nginx"

# 检查nginx用户是否存在，不存在则退出
if ! id -u "${NGINX_USER}" >/dev/null 2>&1; then
  echo >&2 "$ME: warn: ${NGINX_USER} user does not exist, skip chown"
  exit 0
fi

# 检查nginx用户组是否存在，不存在则退出
if ! getent group "${NGINX_GROUP}" >/dev/null 2>&1; then
  echo >&2 "$ME: warn: ${NGINX_GROUP} group does not exist, skip chown"
  exit 0
fi

# 打印nginx用户UID/GID信息
NGINX_UID=$(id -u "${NGINX_USER}")
NGINX_GID=$(getent group "${NGINX_GROUP}" | cut -d: -f3)
echo >&2 "$ME: info: ${NGINX_USER} uid:${NGINX_UID}, gid:${NGINX_GID}"

# 循环创建目录并递归赋权
for dir in ${TARGET_DIRS}; do
  # 创建目录（不存在则创建，忽略已存在）
  mkdir -p "${dir}" >/dev/null 2>&1
  # 递归修改目录属主为nginx:nginx
  chown -R "${NGINX_USER}:${NGINX_GROUP}" "${dir}"
done

echo >&2 "$ME: info: successfully chown dirs: ${TARGET_DIRS}"
