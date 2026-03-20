#!/usr/bin/env bash

read -r -p "请输入项目名称 (用于 docker compose project name): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then
    echo "[install] 项目名称不能为空" >&2
    exit 1
fi

# 检查系统版本
OS_VERSION="$(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release)"

# 判断操作系统类型
if [[ "$OS_VERSION" == *"CentOS"* || "$OS_VERSION" == *"Rocky"* ]]; then
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

# 安装 docker x 插件与兼容命令
if [ -f "./dockerx/docker-x" ]; then
    mkdir -p "$HOME/.docker/cli-plugins"
    cp ./dockerx/docker-x "$HOME/.docker/cli-plugins/docker-x"
    chmod +x "$HOME/.docker/cli-plugins/docker-x"
    echo "[install] 已安装 docker-x 到 $HOME/.docker/cli-plugins/docker-x"
    echo "[install] 可使用: docker x ps / docker x logs"
else
    echo "[install] 未找到 ./dockerx/docker-x，跳过安装 docker-x"
fi

if [ -f "./dockerx/docker-ps" ]; then
    sudo cp ./dockerx/docker-ps /usr/local/bin/docker-ps
    sudo chmod +x /usr/local/bin/docker-ps
    echo "[install] 已安装 docker-ps 兼容命令（内部转发到 docker-x）"
else
    echo "[install] 未找到 ./dockerx/docker-ps，跳过安装 docker-ps"
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
read -r -p "是否重启 Docker 以使 daemon.json 生效? (y/N): " RESTART_DOCKER
if [[ "$RESTART_DOCKER" =~ ^[Yy]$ ]]; then
  echo Restart docker...
  sudo systemctl daemon-reload
  sudo systemctl restart docker
else
  echo "已跳过重启 Docker，daemon.json 变更需重启后生效"
fi

echo "[install] 安装完成，准备启动 infra-base..."

sh start.sh "$PROJECT_NAME"
