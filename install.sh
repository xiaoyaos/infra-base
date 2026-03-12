#!/usr/bin/env bash

echo "[install] 安装完成，准备启动 base_hub..."
read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then
    echo "[install] 项目名称不能为空" >&2
    exit 1
fi

# 检查系统版本
OS_VERSION="$(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release)"

# 判断操作系统类型
if [[ "$OS_VERSION" == *"CentOS"* ]]; then
    echo "当前为 CentOS 系统: $OS_VERSION"
    
elif [[ "$OS_VERSION" == *"Ubuntu"* ]]; then
    echo "当前为 Ubuntu 系统: $OS_VERSION"
    
else
    echo "不支持的操作系统: $OS_VERSION"
    echo "脚本退出"
    exit 1
fi

# 检查Docker是否安装
if which docker > /dev/null 2>&1; then
    # Docker已安装，打印版本信息
    echo 'Docker is installed.'
    echo "Docker version: $(docker --version)"
else
    # Docker未安装，打印提示信息
    echo 'Docker is not installed.'
    if [[ "$OS_VERSION" == *"CentOS"* ]]; then
    	# 第一步 卸载旧版docker相关组件
    	sudo yum remove docker                       docker-client                       docker-client-latest                       docker-common                       docker-latest                       docker-latest-logrotate                       docker-logrotate                       docker-engine
    
    	# 第二步 安装yum-config-manager docker仓库源管理并设置仓库源
    	sudo yum -y install yum-config-manager
    	sudo yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    	# 第三步 安装docker组件
    	sudo yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        # 第一步 卸载旧版docker相关组件
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do 
            sudo apt-get remove  -y  
        done
        # 第二步 安装yum-config-manager docker仓库源管理并设置仓库源
        # Add Docker's official GPG key:
        sudo apt-get update
        sudo apt-get -y install ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        # Add the repository to Apt sources:
        echo           "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc]           https://mirrors.aliyun.com/docker-ce/linux/ubuntu           $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |           sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        # 第三步 安装docker组件
        sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    
    # 第四步 设置系统引导时自动启动
    sudo systemctl enable --now docker
fi

# 检查docker-compose是否安装
# MACHINE_ARCH="$(arch)"
# echo "MACHINE_ARCH $MACHINE_ARCH"
# if which docker-compose > /dev/null 2>&1; then
#     # Docker已安装，打印版本信息
#     echo 'docker-compose is installed.'
#     echo "docker-compose version: $(docker-compose --version)"
# else
# 	echo 'docker-compose is not installed.'
# 	# 下载docker-compose
# 	# curl -SL https://github.com/docker/compose/releases/download/v2.30.3/docker-compose-linux-$MACHINE_ARCH -o /usr/local/bin/docker-compose
#   curl -SL https://gh.zyjs8.com/https://github.com/docker/compose/releases/download/v2.30.3/docker-compose-linux-$MACHINE_ARCH -o /usr/local/bin/docker-compose
#   # 设置可执行权限
# 	chmod +x /usr/local/bin/docker-compose
# fi

sudo mkdir -p /etc/docker
if [ -e /etc/docker/daemon.json ]; then
    mv /etc/docker/daemon.json /etc/docker/daemon.json.bak
else
    echo 'daemon.json does not exist.'
fi
cp docker_daemon.json /etc/docker/daemon.json

# 重启docker
echo Restart docker...
sudo systemctl daemon-reload
sudo systemctl restart docker

sh start.sh "$PROJECT_NAME"
