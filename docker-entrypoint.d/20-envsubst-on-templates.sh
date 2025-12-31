#!/bin/sh
# vim:sw=4:ts=4:et

set -e

entrypoint_log() {
    if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        echo "$@"
    fi
}

ME=$(basename "$0")
NGINX_ENVSUBST_TEMPLATE_DIR=${NGINX_ENVSUBST_TEMPLATE_DIR:-/etc/nginx/templates}
NGINX_ENVSUBST_OUTPUT_DIR=${NGINX_ENVSUBST_OUTPUT_DIR:-/etc/nginx/conf.d}

if [ "$1" = "nginx" ] || [ "$1" = "nginx-debug" ]; then
    if /usr/bin/find "$NGINX_ENVSUBST_TEMPLATE_DIR/" -mindepth 1 -maxdepth 1 -type f -name "*.template" -print -quit 2>/dev/null | read v; then
        entrypoint_log "$ME: Template found in $NGINX_ENVSUBST_TEMPLATE_DIR/, rendering to $NGINX_ENVSUBST_OUTPUT_DIR/"
        /usr/bin/find "$NGINX_ENVSUBST_TEMPLATE_DIR/" -name "*.template" -type f -print0 | sort -z | while read -r -d '' f; do
            reltemplate="${f#$NGINX_ENVSUBST_TEMPLATE_DIR/}"
            reloutput="${reltemplate%.*}"
            output="$NGINX_ENVSUBST_OUTPUT_DIR/$reloutput"
            entrypoint_log "$ME: Rendering $f to $output"
            envsubst < "$f" > "$output"
        done
    else
        entrypoint_log "$ME: No templates found in $NGINX_ENVSUBST_TEMPLATE_DIR/"
    fi
fi
