#!/bin/bash
# ============================================================
# File:        install_carbonledger.cloud.sh
# Description: 一键编译安装 Nginx 1.29.8 + LuaJIT + lua-resty-core + Vector
#              集成 Nginx 模块：ngx_devel_kit, lua-nginx-module, nginx-upload-module
#              自动安装 Vector 并监控 upload_store 目录
# Author:      carbonledger.cloud
# ============================================================

# ---------- 编译配置 ----------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR="${SCRIPT_DIR}/../cloud.carbonledger"
WORK_DIR="${SCRIPT_DIR}/../packages"

NGINX_VERSION="1.29.8"
LUAJIT_REPO="https://github.com/openresty/luajit2.git"
ZLIB_REPO="https://github.com/madler/zlib.git"
LUAJIT_BRANCH="v2.1-20250826"
NDK_VERSION="0.3.3"
LUA_NGINX_VERSION="0.10.30rc2"
ZLIB_BRANCH="v1.3.2"
UPLOAD_MODULE_VERSION="2.3.0"
LUA_RESTY_CORE_VERSION="0.1.33rc2"
LUAJIT_HOME="${BASE_DIR}/luajit"
NGINX_HOME="${BASE_DIR}/nginx"

# Vector 配置
VECTOR_VERSION="latest"
VECTOR_HOME="${BASE_DIR}/vector"
VECTOR_CONFIG_DIR="${VECTOR_HOME}/config"
VECTOR_DATA_DIR="${VECTOR_HOME}/data"
VECTOR_LOGS_DIR="${VECTOR_HOME}/logs"
UPLOAD_STORE_DIR="${NGINX_HOME}/upload_tmp"

# 输出类型 (可按需修改为 kafka, redis, elasticsearch, logstash, nats 等)
OUTPUT_TYPE="console"
# 以下为可选输出参数，根据 OUTPUT_TYPE 启用
KAFKA_BOOTSTRAP_SERVERS="localhost:9092"
KAFKA_TOPIC="nginx-uploads"
REDIS_HOST="localhost"
REDIS_PORT="6379"
REDIS_KEY="nginx-uploads"
ELASTICSEARCH_HOST="localhost:9200"
ELASTICSEARCH_INDEX="nginx-uploads"
LOGSTASH_HOST="localhost:5044"
NATS_URL="nats://localhost:4222"
NATS_SUBJECT="nginx-uploads"

# CPU 核心数 & macOS 兼容
if [[ "$(uname)" == "Darwin" ]]; then
    CPU_CORES=$(sysctl -n hw.ncpu)
    ARCH=$(uname -m)
    export MACOSX_DEPLOYMENT_TARGET=$(sw_vers -productVersion)
    export CFLAGS="-arch ${ARCH}"
    export LDFLAGS="-arch ${ARCH}"
    export HOMEBREW_PREFIX=$(brew --prefix)
    export PKG_CONFIG_PATH="${HOMEBREW_PREFIX}/opt/openssl/lib/pkgconfig"
else
    CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
fi

set -e

# ---------- 1. 安装编译依赖 ----------
echo "[1/15] 安装编译依赖..."
if command -v yum &> /dev/null; then
    yum install -y epel-release
    yum install -y gcc gcc-c++ make automake autoconf libtool \
        pcre-devel zlib-devel openssl-devel curl wget unzip git
elif command -v apt &> /dev/null; then
    apt update -y
    apt install -y build-essential libpcre3-dev zlib1g-dev \
        libssl-dev curl wget unzip git
elif command -v dnf &> /dev/null; then
    dnf install -y gcc gcc-c++ make automake autoconf libtool \
        pcre-devel zlib-devel openssl-devel curl wget unzip git
elif [[ "$(uname)" == "Darwin" ]]; then
    if ! command -v brew &> /dev/null; then
        echo "[-] 未检测到 Homebrew，请先安装: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    brew install gcc make automake autoconf libtool pcre zlib openssl curl wget unzip git
else
    echo "[-] 无法识别包管理器，请手动安装编译环境"
    exit 1
fi
echo "[+] 编译依赖安装完成"

# ---------- 2. 创建工作目录 ----------
echo "[2/15] 创建工作目录 ${WORK_DIR} ..."
mkdir -p ${WORK_DIR}
cd ${WORK_DIR}
rm -rf ./*
mkdir -p ${BASE_DIR}
chmod -R +w ${BASE_DIR}
mkdir -p ${LUAJIT_HOME}
chmod -R +w ${LUAJIT_HOME}
mkdir -p ${NGINX_HOME}
chmod -R +w ${NGINX_HOME}
# 创建 Vector 相关目录
mkdir -p ${VECTOR_HOME}
chmod -R +w ${VECTOR_HOME}
mkdir -p ${VECTOR_CONFIG_DIR} ${VECTOR_DATA_DIR} ${VECTOR_LOGS_DIR}
chmod -R +w ${VECTOR_CONFIG_DIR} ${VECTOR_DATA_DIR} ${VECTOR_LOGS_DIR}

# ---------- 3. 下载 zlib ----------
echo "[3/15] 下载 zlib ..."
git clone --depth 1 --branch ${ZLIB_BRANCH} ${ZLIB_REPO} zlib

# ---------- 4. 下载 LuaJIT ----------
echo "[4/15] 下载 LuaJIT ..."
git clone --depth 1 --branch ${LUAJIT_BRANCH} ${LUAJIT_REPO} luajit2

# ---------- 5. 编译安装 LuaJIT ----------
echo "[5/15] 编译安装 LuaJIT ..."
cd ${WORK_DIR}/luajit2
make CC="gcc -arch ${ARCH}" CFLAGS="-arch ${ARCH}" LDFLAGS="-arch ${ARCH}" -j${CPU_CORES} TARGET_DYLIBPATH="@rpath/libluajit-5.1.2.dylib" TARGET_DYLIBNAME="libluajit-5.1.2.dylib"
make install PREFIX="${LUAJIT_HOME}" CC="gcc -arch ${ARCH}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "${LUAJIT_HOME}/lib" > /etc/ld.so.conf.d/luajit.conf
    ldconfig
fi
export LUAJIT_LIB=${LUAJIT_HOME}/lib
export LUAJIT_INC=${LUAJIT_HOME}/include/luajit-2.1
echo "[+] LuaJIT 安装完成"

# ---------- 6. 下载 ngx_devel_kit ----------
echo "[6/15] 下载 ngx_devel_kit ..."
cd ${WORK_DIR}
wget -c https://github.com/simpl/ngx_devel_kit/archive/v${NDK_VERSION}.tar.gz -O ndk-${NDK_VERSION}.tar.gz
tar -zxf ndk-${NDK_VERSION}.tar.gz
mv ngx_devel_kit-${NDK_VERSION} ndk-${NDK_VERSION}

# ---------- 7. 下载 lua-nginx-module ----------
echo "[7/15] 下载 lua-nginx-module ..."
wget -c https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_VERSION}.tar.gz -O lua-module-${LUA_NGINX_VERSION}.tar.gz
tar -zxf lua-module-${LUA_NGINX_VERSION}.tar.gz
mv lua-nginx-module-${LUA_NGINX_VERSION} lua-module-${LUA_NGINX_VERSION}

# ---------- 8. 下载 nginx-upload-module ----------
echo "[8/15] 下载 nginx-upload-module ..."
UPLOAD_MODULE_DIR="nginx-upload-module-${UPLOAD_MODULE_VERSION}"
wget -c https://github.com/fdintino/nginx-upload-module/archive/refs/tags/${UPLOAD_MODULE_VERSION}.tar.gz -O upload-module-${UPLOAD_MODULE_VERSION}.tar.gz
tar -zxf upload-module-${UPLOAD_MODULE_VERSION}.tar.gz
if [ ! -d "${UPLOAD_MODULE_DIR}" ]; then
    mv nginx-upload-module-* ${UPLOAD_MODULE_DIR} 2>/dev/null || true
fi

# ---------- 8.4 下载并安装 lua-resty-lrucache ----------
echo "[8.4/15] 下载 lua-resty-lrucache ..."
cd ${WORK_DIR}
git clone --depth 1 https://github.com/openresty/lua-resty-lrucache.git lua-resty-lrucache
LUA_SHARE_DIR="${LUAJIT_HOME}/share/lua/5.1"
mkdir -p ${LUA_SHARE_DIR}
cp -r lua-resty-lrucache/lib/resty ${LUA_SHARE_DIR}/
echo "[+] lua-resty-lrucache 已安装到 ${LUA_SHARE_DIR}/resty"

# ---------- 8.5 下载并安装 lua-resty-core ----------
echo "[8.5/15] 下载 lua-resty-core v${LUA_RESTY_CORE_VERSION} ..."
cd ${WORK_DIR}
git clone --depth 1 --branch v${LUA_RESTY_CORE_VERSION} https://github.com/openresty/lua-resty-core.git lua-resty-core-${LUA_RESTY_CORE_VERSION}
cp -r lua-resty-core-${LUA_RESTY_CORE_VERSION}/lib/* ${LUA_SHARE_DIR}/
echo "[+] lua-resty-core 已安装到 ${LUA_SHARE_DIR}"

# ---------- 9. 下载 Nginx ----------
echo "[9/15] 下载 Nginx ..."
cd ${WORK_DIR}
wget -c http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
tar -zxf nginx-${NGINX_VERSION}.tar.gz

# ---------- 10. 编译 Nginx ----------
echo "[10/15] 编译 Nginx ..."
cd nginx-${NGINX_VERSION}
export LUAJIT_LIB=${LUAJIT_HOME}/lib
export LUAJIT_INC=${LUAJIT_HOME}/include/luajit-2.1
./configure \
    --prefix=${NGINX_HOME} \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-zlib=${WORK_DIR}/zlib \
    --with-ld-opt="-Wl,-rpath,${LUAJIT_HOME}/lib" \
    --add-module=${WORK_DIR}/ndk-${NDK_VERSION} \
    --add-module=${WORK_DIR}/lua-module-${LUA_NGINX_VERSION} \
    --add-module=${WORK_DIR}/${UPLOAD_MODULE_DIR}
make -j${CPU_CORES}
make install
echo "[+] Nginx 编译安装完成"

# ---------- 11. 配置 lua 路径和测试配置文件 ----------
echo "[11/15] 配置 lua_package_path 并创建测试配置..."
mkdir -p ${NGINX_HOME}/conf/conf.d

cat > ${NGINX_HOME}/conf/conf.d/00_lua_package.conf << EOF
lua_package_path '${LUAJIT_HOME}/share/lua/5.1/?.lua;;';
EOF

cat > ${NGINX_HOME}/conf/conf.d/test_lua.conf << 'EOF'
server {
    listen 8080;
    server_name localhost;
    location /lua-test {
        default_type 'text/html';
        content_by_lua_block {
            ngx.say("Hello, Nginx + LuaJIT works!")
        }
    }
    location /lua-resty-version {
        default_type 'text/plain';
        content_by_lua_block {
            local ok, msg = pcall(require, "resty.core")
            ngx.say("ngx_lua version: ", ngx.config.ngx_lua_version)
            if ok then
                local core = require "resty.core"
                ngx.say("lua-resty-core loaded, version: ", core.version())
            else
                ngx.say("lua-resty-core load failed: ", msg)
                ngx.say("Please ensure lua-resty-lrucache is installed.")
            end
        }
    }
}
EOF

cat > ${NGINX_HOME}/conf/conf.d/test_upload.conf << EOF
server {
    listen 8081;
    server_name localhost;
    client_max_body_size 0;
    location /upload {
        upload_pass @upload_handler;
        upload_store ${NGINX_HOME}/upload_tmp 1;
        upload_store_access user:r;
        upload_set_form_field \$upload_field_name.name "\$upload_file_name";
        upload_set_form_field \$upload_field_name.content_type "\$upload_content_type";
        upload_set_form_field \$upload_field_name.path "\$upload_tmp_path";
        upload_aggregate_form_field \$upload_field_name.size "\$upload_file_size";
        upload_cleanup 400 404 499 500-505;
    }
    location @upload_handler {
        default_type 'text/plain';
        return 200 "Upload successful! File stored at \$arg_path\n";
    }
}
EOF

mkdir -p ${NGINX_HOME}/upload_tmp/{0,1,2,3,4,5,6,7,8,9}

if ! grep -q "include conf.d/\*.conf" ${NGINX_HOME}/conf/nginx.conf; then
    awk '/http {/ { print; print "    include conf.d/*.conf;"; next }1' \
        ${NGINX_HOME}/conf/nginx.conf > ${NGINX_HOME}/conf/nginx.conf.tmp && \
        mv ${NGINX_HOME}/conf/nginx.conf.tmp ${NGINX_HOME}/conf/nginx.conf
fi

# ---------- 12. 安装 Vector ----------
echo "[12/15] 安装 Vector (监控 upload_store) ..."

# 检测操作系统和架构
if [[ "$(uname)" == "Darwin" ]]; then
    V_OS="apple-darwin"
    V_ARCH=$(uname -m)
    if [[ "${V_ARCH}" == "arm64" ]]; then
        #V_ARCH="aarch64"
        V_ARCH="arm64"
    elif [[ "${V_ARCH}" == "x86_64" ]]; then
        V_ARCH="x86_64"
    else
        echo "[-] 不支持的架构: ${V_ARCH}"
        exit 1
    fi
    PACKAGE="vector-${VECTOR_VERSION}-${V_ARCH}-${V_OS}.tar.gz"
    DOWNLOAD_URL="https://packages.timber.io/vector/${VECTOR_VERSION}/${PACKAGE}"
else
    V_OS="unknown-linux-gnu"
    V_ARCH=$(uname -m)
    if [[ "${V_ARCH}" == "x86_64" ]]; then
        V_ARCH="x86_64"
    elif [[ "${V_ARCH}" == "aarch64" ]]; then
        V_ARCH="aarch64"
    else
        echo "[-] 不支持的架构: ${V_ARCH}"
        exit 1
    fi
    PACKAGE="vector-${VECTOR_VERSION}-${V_ARCH}-${V_OS}.tar.gz"
    DOWNLOAD_URL="https://packages.timber.io/vector/${VECTOR_VERSION}/${PACKAGE}"
fi

cd "${WORK_DIR}"
if [ ! -f "${PACKAGE}" ]; then
    echo "    下载 Vector ${VECTOR_VERSION} ..."
    curl -L -O "${DOWNLOAD_URL}"
fi

echo "    解压 Vector 到 ${VECTOR_HOME}"
tar -xzvf "${PACKAGE}" -C "${VECTOR_HOME}" --strip-components=1
VECTOR_CMD="${VECTOR_HOME}/vector-${V_ARCH}-${V_OS}/bin/vector"
chmod +x "${VECTOR_CMD}"

# 生成 Vector 配置（TOML 格式）
echo "    生成 Vector 配置: ${VECTOR_CONFIG_DIR}/vector.toml"

# 基础配置：输入源
cat > "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
# 数据目录，用于持久化文件偏移量
data_dir = "${VECTOR_DATA_DIR}"

[sources.nginx_upload]
type = "file"
include = ["${UPLOAD_STORE_DIR}/*/*"]
ignore_older_secs = 600

[transforms.annotate]
type = "remap"
inputs = ["nginx_upload"]
source = '''
  # 若文件内容是 JSON，则解析；否则保留原始内容
  . = parse_json(string!(.message)) ?? {"raw": .message}
  .log_type = "nginx_upload"
'''

EOF

# 根据输出类型生成对应的 sink
case "$OUTPUT_TYPE" in
    console)
        cat >> "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
[sinks.print_to_console]
type = "console"
inputs = ["annotate"]
encoding.codec = "json"
EOF
        ;;
    kafka)
        cat >> "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
[sinks.send_to_kafka]
type = "kafka"
inputs = ["annotate"]
bootstrap_servers = "${KAFKA_BOOTSTRAP_SERVERS}"
topic = "${KAFKA_TOPIC}"
encoding.codec = "json"
EOF
        ;;
    redis)
        cat >> "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
[sinks.send_to_redis]
type = "redis"
inputs = ["annotate"]
url = "redis://${REDIS_HOST}:${REDIS_PORT}/"
list_key = "${REDIS_KEY}"
encoding.codec = "json"
EOF
        ;;
    elasticsearch)
        cat >> "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
[sinks.send_to_elasticsearch]
type = "elasticsearch"
inputs = ["annotate"]
endpoints = ["http://${ELASTICSEARCH_HOST}:9200"]
index = "${ELASTICSEARCH_INDEX}"
encoding.codec = "json"
EOF
        ;;
    logstash)
        cat >> "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
[sinks.send_to_logstash]
type = "socket"
inputs = ["annotate"]
address = "${LOGSTASH_HOST}:5044"
mode = "tcp"
encoding.codec = "json"
EOF
        ;;
    nats)
        cat >> "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
[sinks.send_to_nats]
type = "nats"
inputs = ["annotate"]
url = "${NATS_URL}"
subject = "${NATS_SUBJECT}"
encoding.codec = "json"
EOF
        ;;
    *)
        echo "[-] 无效的 OUTPUT_TYPE: $OUTPUT_TYPE，使用默认 console"
        cat >> "${VECTOR_CONFIG_DIR}/vector.toml" <<EOF
[sinks.print_to_console]
type = "console"
inputs = ["annotate"]
encoding.codec = "json"
EOF
        ;;
esac

# 创建启停脚本
cat > "${VECTOR_HOME}/start.sh" <<EOF
#!/bin/bash
cd "${VECTOR_HOME}"
export VECTOR_DATA_DIR="${VECTOR_DATA_DIR}"
nohup ./bin/vector --config "${VECTOR_CONFIG_DIR}/vector.toml" > "${VECTOR_LOGS_DIR}/vector.out" 2>&1 &
echo \$! > vector.pid
echo "Vector 已启动，PID: \$(cat vector.pid)"
echo "输出日志: tail -f ${VECTOR_LOGS_DIR}/vector.out"
EOF

cat > "${VECTOR_HOME}/stop.sh" <<EOF
#!/bin/bash
if [ -f "${VECTOR_HOME}/vector.pid" ]; then
    PID=\$(cat "${VECTOR_HOME}/vector.pid")
    kill \$PID && rm "${VECTOR_HOME}/vector.pid"
    echo "Vector (PID \$PID) 已停止"
else
    echo "未找到 PID 文件，尝试 pkill vector"
    pkill -f "bin/vector" && echo "已停止" || echo "未发现运行中的 Vector"
fi
EOF

chmod +x "${VECTOR_HOME}/start.sh" "${VECTOR_HOME}/stop.sh"

# 测试配置
echo "    测试 Vector 配置"
${VECTOR_CMD} validate "${VECTOR_CONFIG_DIR}/vector.toml" > /dev/null 2>&1 || {
    echo "${VECTOR_CMD} validate "${VECTOR_CONFIG_DIR}/vector.toml" > /dev/null 2>&1"
    echo "[-] Vector 配置测试失败，请检查配置文件"
    exit 1
}

echo "[+] Vector 安装完成"

# ---------- 13. 完成 ----------
echo "[13/15] Nginx + Vector 安装完成！"
echo "[14/15] 输出使用说明"
echo "============================================="
echo "[*] Nginx 安装路径: ${NGINX_HOME}"
echo "[*] 启动命令:       ${NGINX_HOME}/sbin/nginx"
echo "[*] 重载配置:       ${NGINX_HOME}/sbin/nginx -s reload"
echo "[*] 停止服务:       ${NGINX_HOME}/sbin/nginx -s stop"
echo ""
echo "[*] 测试 Lua 基础功能:"
echo "    curl http://localhost:8080/lua-test"
echo "[*] 检查 Lua 版本及 resty.core 状态:"
echo "    curl http://localhost:8080/lua-resty-version"
echo "[*] 测试 upload 模块:"
echo "    curl -F 'file=@/etc/hosts' http://localhost:8081/upload"
echo ""
echo "[*] Vector 安装目录: ${VECTOR_HOME}"
echo "[*] 启动 Vector:     ${VECTOR_HOME}/start.sh"
echo "[*] 停止 Vector:     ${VECTOR_HOME}/stop.sh"
echo "[*] 查看 Vector 输出: tail -f ${VECTOR_LOGS_DIR}/vector.out"
echo ""
echo "[*] 注意: Vector 仅监控 upload_store 目录，如需修改输出类型请在脚本开头修改 OUTPUT_TYPE"
if [[ "$(uname)" == "Darwin" ]]; then
    echo "[*] macOS 注意: 启动 nginx 前请设置: export DYLD_LIBRARY_PATH=${LUAJIT_HOME}/lib:\$DYLD_LIBRARY_PATH"
fi
echo "============================================="
echo "[15/15] 脚本执行完毕"
