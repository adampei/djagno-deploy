#!/bin/bash

# 确保脚本以root权限运行
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# 交互式配置
read -p "请输入项目域名 (例如: example.com): " DOMAIN_NAME
read -p "请输入Git仓库地址: " GIT_REPO
read -p "请输入项目安装路径 [/opt]: " BASE_PATH
BASE_PATH=${BASE_PATH:-/opt}

# 设置基础变量
SOCKET_PATH="/run"
WORKERS=3

# 安装必要的系统包
apt-get update
apt-get install -y python3-venv python3-pip nginx git

# 配置Git
git config --global core.fileMode true

# 克隆项目并获取项目名
cd ${BASE_PATH}
echo "正在克隆项目..."
git clone ${GIT_REPO}
if [ $? -ne 0 ]; then
    echo "Git克隆失败!"
    exit 1
fi

# 自动获取项目文件夹名作为项目名
PROJECT_NAME=$(basename `ls -td ${BASE_PATH}/*/ | head -1`)
PROJECT_PATH="${BASE_PATH}/${PROJECT_NAME}"
VIRTUAL_ENV="${PROJECT_PATH}/venv"
SOCKET_FILE="${SOCKET_PATH}/${PROJECT_NAME}.sock"

echo "配置信息:"
echo "域名: ${DOMAIN_NAME}"
echo "Git仓库: ${GIT_REPO}"
echo "项目名称: ${PROJECT_NAME}"
echo "项目路径: ${PROJECT_PATH}"
read -p "确认以上信息正确? [y/N] " CONFIRM
if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
    echo "已取消部署"
    rm -rf ${PROJECT_PATH}  # 清理已克隆的代码
    exit 1
fi

# 创建必要的目录并设置权限
mkdir -p ${PROJECT_PATH}/static
mkdir -p ${PROJECT_PATH}/media
# 设置目录权限为755 (rwxr-xr-x)
chmod -R 755 ${PROJECT_PATH}
# 确保 media 目录可写
chmod -R 777 ${PROJECT_PATH}/media

# 创建并激活虚拟环境
python3 -m venv ${VIRTUAL_ENV}
source ${VIRTUAL_ENV}/bin/activate

# 安装依赖
if [ -f "${PROJECT_PATH}/requirements.txt" ]; then
    echo "正在安装项目依赖..."
    pip install -r ${PROJECT_PATH}/requirements.txt
else
    echo "未找到requirements.txt，安装基本依赖..."
    pip install django gunicorn
fi

# 创建 gunicorn.service
cat > /etc/systemd/system/${PROJECT_NAME}.service << EOL
[Unit]
Description=Gunicorn daemon for ${PROJECT_NAME}
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=${PROJECT_PATH}
ExecStart=${VIRTUAL_ENV}/bin/gunicorn \
    --workers ${WORKERS} \
    --bind unix:${SOCKET_FILE} \
    ${PROJECT_NAME}.wsgi:application
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL

# 直接创建 Nginx 配置到 sites-enabled
cat > /etc/nginx/sites-enabled/${PROJECT_NAME}.conf << EOL
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    access_log /var/log/nginx/${PROJECT_NAME}_access.log;
    error_log /var/log/nginx/${PROJECT_NAME}_error.log;

    location = /favicon.ico { 
        access_log off; 
        log_not_found off; 
    }

    location /static/ {
        alias ${PROJECT_PATH}/static/;
        expires 30d;
        access_log off;
    }

    location /media/ {
        alias ${PROJECT_PATH}/media/;
        expires 30d;
        access_log off;
    }

    location / {
        proxy_pass http://unix:${SOCKET_FILE};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # 基本安全配置
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Frame-Options DENY;
}
EOL

# 确保nginx配置正确
nginx -t

# 收集静态文件
echo "正在收集静态文件..."
cd ${PROJECT_PATH}
${VIRTUAL_ENV}/bin/python manage.py collectstatic --noinput

# 启动服务
systemctl daemon-reload
systemctl start ${PROJECT_NAME}
systemctl enable ${PROJECT_NAME}
systemctl restart nginx

# 检查服务状态
echo "正在检查服务状态..."
systemctl status ${PROJECT_NAME}
systemctl status nginx

echo -e "\n部署完成!"
echo "请检查以下事项:"
echo "1. 确保域名 ${DOMAIN_NAME} 已经正确解析到服务器"
echo "2. 检查 Django settings.py 中的生产环境配置:"
echo "   STATIC_ROOT = '${PROJECT_PATH}/static'"
echo "   MEDIA_ROOT = '${PROJECT_PATH}/media'"
echo "   ALLOWED_HOSTS = ['${DOMAIN_NAME}']"
echo "3. 考虑配置 SSL 证书"
echo "4. 检查日志文件: "
echo "   - Nginx 日志: /var/log/nginx/${PROJECT_NAME}_access.log"
echo "   - Nginx 错误日志: /var/log/nginx/${PROJECT_NAME}_error.log"
echo "   - Gunicorn 日志: journalctl -u ${PROJECT_NAME}"

# 显示常用命令
echo -e "\n常用命令:"
echo "重启 Django 服务: systemctl restart ${PROJECT_NAME}"
echo "查看 Django 日志: journalctl -u ${PROJECT_NAME}"
echo "重启 Nginx: systemctl restart nginx"
echo "更新代码:"
echo "  cd ${PROJECT_PATH}"
echo "  git pull"
echo "  systemctl restart ${PROJECT_NAME}"
