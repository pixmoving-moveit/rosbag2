#!/bin/bash
#
# rosbag2 Debian 包打包脚本
# 按照 colcon graph 依赖顺序从上到下打包
#

set -e  # 遇到错误立即退出

# 检查并安装必要的依赖包
check_and_install_deps() {
    local deps=("python3-bloom" "python3-rosdep" "fakeroot" "debhelper" "dh-python")
    local missing_deps=()
    
    echo "[检查] 检查必要的依赖包..."
    
    for dep in "${deps[@]}"; do
        if ! dpkg -l | grep -q "^ii  $dep "; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "[安装] 发现缺失的依赖包: ${missing_deps[*]}"
        echo "[安装] 正在安装依赖..."
        sudo apt update
        sudo apt install -y "${missing_deps[@]}"
        echo "[安装] 依赖安装完成"
    else
        echo "[检查] 所有依赖包已安装"
    fi
    echo ""
}

# 执行依赖检查
check_and_install_deps

# 显示帮助信息
show_help() {
    echo "用法: $0 <src_relative_path> [package_name]"
    echo ""
    echo "参数:"
    echo "  src_relative_path    源码根目录的相对路径（相对于当前工作空间）"
    echo "  package_name         (可选) 指定要打包的单个功能包名称"
    echo "                       如果不指定，则打包所有功能包"
    echo ""
    echo "示例:"
    echo "  cd ~/pix/test/ros2_ws"
    echo "  $0 src/rosbag2                    # 打包所有功能包"
    echo "  $0 src/rosbag2 rosbag2_cpp        # 只打包 rosbag2_cpp"
    echo "  $0 src rosbag2_cpp                # 从 src 目录中只打包 rosbag2_cpp"
    exit 1
}

# 检查参数
if [ $# -lt 1 ]; then
    echo "[错误] 缺少参数：请提供源码根目录的相对路径"
    show_help
fi

# 配置
WORKSPACE_DIR="$(pwd)"
SRC_RELATIVE_PATH="$1"
SRC_DIR="$WORKSPACE_DIR/$SRC_RELATIVE_PATH"
INSTALL_DIR="$WORKSPACE_DIR/install"
DEB_OUTPUT_DIR="$WORKSPACE_DIR/deb_packages"
BUILD_PREFIX="pix$(date +%Y%m%d)-"
ROS_DISTRO="humble"

# 可选的指定包名
SPECIFIC_PACKAGE=""
if [ $# -ge 2 ]; then
    SPECIFIC_PACKAGE="$2"
fi

# 验证源码目录存在
if [ ! -d "$SRC_DIR" ]; then
    echo "[错误] 源码目录不存在: $SRC_DIR"
    exit 1
fi

# 创建输出目录
mkdir -p "$DEB_OUTPUT_DIR"

# 清理函数：删除生成的 debian 目录和中间文件
cleanup_debian_files() {
    local pkg_dir="$1"
    echo "  [清理] 删除 $pkg_dir 中的 debian 生成文件..."
    rm -rf "$pkg_dir/debian"
    rm -rf "$pkg_dir/obj-x86_64-linux-gnu"
    rm -rf "$pkg_dir/.obj-x86_64-linux-gnu"
    rm -rf "$pkg_dir/.pybuild"
    rm -rf "$pkg_dir"/*.egg-info
    rm -f "$pkg_dir"/*.debhelper.log
    rm -f "$pkg_dir"/*.debhelper
    rm -f "$pkg_dir"/*.substvars
    rm -f "$pkg_dir"/files
    rm -f "$pkg_dir"/../ros-humble-*.deb
    rm -f "$pkg_dir"/../ros-humble-*.ddeb
    rm -f "$pkg_dir"/../ros-humble-*.changes
    rm -f "$pkg_dir"/../ros-humble-*.dsc
    rm -f "$pkg_dir"/../ros-humble-*.tar.xz
}

# 打包单个包的函数
build_deb_package() {
    local pkg_name="$1"
    local pkg_dir="$SRC_DIR/$pkg_name"
    
    echo "========================================"
    echo "正在打包: $pkg_name"
    echo "========================================"
    
    # 检查包目录是否存在
    if [ ! -d "$pkg_dir" ]; then
        echo "[警告] 包目录不存在: $pkg_dir, 跳过..."
        return 0
    fi
    
    # 检查是否已存在生成的 deb 包，避免重复打包
    local existing_deb=("$DEB_OUTPUT_DIR"/ros-${ROS_DISTRO}-${pkg_name//_/-}_*.deb)
    if [ -f "${existing_deb[0]}" ]; then
        echo "  [跳过] deb 包已存在，无需重复打包"
        echo "         位置: ${existing_deb[0]}"
        # 确保包已安装
        local deb_name="ros-${ROS_DISTRO}-${pkg_name//_/-}"
        if ! dpkg -l | grep -q "^ii  $deb_name "; then
            echo "  [安装] 安装已存在的 deb 包..."
            for deb_file in "${existing_deb[@]}"; do
                if [ -f "$deb_file" ]; then
                    sudo dpkg -i "$deb_file" || {
                        echo "[错误] 安装 $deb_file 失败"
                        return 1
                    }
                fi
            done
        fi
        # 记录本次安装的包名
        INSTALLED_PACKAGES+=("$deb_name")
        echo "[完成] $pkg_name 处理完成"
        echo ""
        return 0
    fi
    
    # 进入包目录
    cd "$pkg_dir"
    
    # 清理可能存在的旧文件
    cleanup_debian_files "$pkg_dir"
    
    # 生成 debian 文件
    echo "  [1/3] 生成 debian 文件..."
    bloom-generate rosdebian -i "$BUILD_PREFIX" --os-name ubuntu --os-version jammy --ros-distro "$ROS_DISTRO"
    
    # 构建 deb 包
    echo "  [2/3] 构建 deb 包..."
    fakeroot debian/rules binary
    
    # 移动生成的 deb 包到输出目录
    echo "  [3/3] 移动 deb 包到输出目录..."
    
    # deb 文件可能生成在源码父目录或 deb_packages 目录
    local deb_files_src=("$pkg_dir"/../ros-${ROS_DISTRO}-${pkg_name//_/-}_*.deb)
    local deb_files_deb=("$DEB_OUTPUT_DIR"/ros-${ROS_DISTRO}-${pkg_name//_/-}_*.deb)
    local found_deb=false
    
    # 检查源码父目录
    if [ -f "${deb_files_src[0]}" ]; then
        for deb_file in "${deb_files_src[@]}"; do
            if [ -f "$deb_file" ]; then
                local deb_name=$(basename "$deb_file")
                echo "    找到: $deb_name"
                mv "$deb_file" "$DEB_OUTPUT_DIR/"
                found_deb=true
            fi
        done
    fi
    
    # 检查是否已经在 deb_packages 目录
    if [ "$found_deb" = false ] && [ -f "${deb_files_deb[0]}" ]; then
        echo "    deb 包已在输出目录中"
        found_deb=true
    fi
    
    if [ "$found_deb" = false ]; then
        echo "[错误] 未找到生成的 deb 文件"
        echo "       查找位置: ${deb_files_src[0]}"
        echo "       查找位置: ${deb_files_deb[0]}"
        cleanup_debian_files "$pkg_dir"
        return 1
    fi
    
    # 清理生成的文件
    cleanup_debian_files "$pkg_dir"
    
    # 安装生成的 deb 包（用于后续包的依赖）
    echo "  [安装] 安装生成的 deb 包..."
    local installed_deb=("$DEB_OUTPUT_DIR"/ros-${ROS_DISTRO}-${pkg_name//_/-}_*.deb)
    if [ -f "${installed_deb[0]}" ]; then
        for deb_file in "${installed_deb[@]}"; do
            if [ -f "$deb_file" ]; then
                sudo dpkg -i "$deb_file" || {
                    echo "[错误] 安装 $deb_file 失败"
                    return 1
                }
            fi
        done
    fi
    
    # 记录本次安装的包名
    INSTALLED_PACKAGES+=("ros-${ROS_DISTRO}-${pkg_name//_/-}")
    
    echo "[完成] $pkg_name 打包并安装成功"
    echo ""
    
    return 0
}

# 主流程
echo "========================================"
echo "rosbag2 Debian 包打包脚本"
echo "========================================"
echo "工作空间: $WORKSPACE_DIR"
echo "源码根目录: $SRC_DIR (相对路径: $SRC_RELATIVE_PATH)"
echo "输出目录: $DEB_OUTPUT_DIR"
echo "构建前缀: $BUILD_PREFIX"
echo "ROS Distro: $ROS_DISTRO"
if [ -n "$SPECIFIC_PACKAGE" ]; then
    echo "指定打包: $SPECIFIC_PACKAGE (仅打包此功能包)"
else
    echo "打包范围: 所有功能包"
fi
echo "========================================"
echo ""

# 检查必要工具
echo "[检查] 检查必要工具..."
for tool in bloom-generate fakeroot dpkg; do
    if ! command -v "$tool" &> /dev/null; then
        echo "[错误] 未找到工具: $tool"
        exit 1
    fi
done
echo "[检查] 所有工具已安装"
echo ""

# 确保工作目录存在
cd "$WORKSPACE_DIR"

#  source 当前 install 环境（如果有）
if [ -f "$INSTALL_DIR/setup.bash" ]; then
    echo "[环境] source $INSTALL_DIR/setup.bash"
    source "$INSTALL_DIR/setup.bash"
fi

# 记录本次脚本安装的包
INSTALLED_PACKAGES=()

# 如果指定了特定包，直接打包该包
if [ -n "$SPECIFIC_PACKAGE" ]; then
    echo "[信息] 指定打包单个功能包: $SPECIFIC_PACKAGE"
    
    # 检查包目录是否存在
    if [ ! -d "$SRC_DIR/$SPECIFIC_PACKAGE" ]; then
        echo "[错误] 指定的功能包不存在: $SRC_DIR/$SPECIFIC_PACKAGE"
        exit 1
    fi
    
    # 检查是否有 package.xml
    if [ ! -f "$SRC_DIR/$SPECIFIC_PACKAGE/package.xml" ]; then
        echo "[错误] 指定的目录不是有效的 ROS 包（缺少 package.xml）: $SRC_DIR/$SPECIFIC_PACKAGE"
        exit 1
    fi
    
    echo ""
    if ! build_deb_package "$SPECIFIC_PACKAGE"; then
        echo "[错误] 打包 $SPECIFIC_PACKAGE 失败，脚本终止"
        exit 1
    fi
    
    echo "========================================"
    echo "指定功能包打包完成！"
    echo "输出目录: $DEB_OUTPUT_DIR"
    echo "生成的包列表:"
    ls -lh "$DEB_OUTPUT_DIR/"
    echo ""
    echo "已安装的功能包:"
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        dpkg -l | grep "^ii  $pkg " | awk '{printf "  %-40s %s\n", $2, $3}'
    done
    echo "========================================"
    exit 0
fi

# 从 colcon graph 提取包列表（按依赖顺序，从上到下）
echo "[信息] 从 colcon graph 提取包依赖顺序..."
if ! command -v colcon &> /dev/null; then
    echo "[错误] 未找到 colcon 工具，无法提取依赖顺序"
    exit 1
fi

# 提取包名（第一列），保持 colcon graph 输出的从上到下顺序
# colcon graph 输出格式: 包名 + 依赖关系图
# 我们只需要第一列的包名，这就是依赖顺序（从上到下，依赖少的在前）
PACKAGES=()
while IFS= read -r line; do
    # 提取第一列（包名），去除前后空格
    pkg_name=$(echo "$line" | awk '{print $1}' | tr -d '[:space:]')
    # 跳过空行
    if [ -n "$pkg_name" ]; then
        # 检查该包是否在指定的源码目录中
        if [ -d "$SRC_DIR/$pkg_name" ]; then
            PACKAGES+=("$pkg_name")
        else
            echo "  [跳过] 包 '$pkg_name' 不在源码目录 $SRC_RELATIVE_PATH 中"
        fi
    fi
done < <(cd "$SRC_DIR" && colcon graph 2>/dev/null || true)
# 清理 colcon graph 生成的 log 目录
if [ -d "$SRC_DIR/log" ]; then
    rm -rf "$SRC_DIR/log"
    echo "  [清理] 删除 colcon graph 生成的 log 目录"
fi

# 检查是否提取到包
if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo "[错误] 未能从 colcon graph 提取到任何包"
    echo "       请确保在正确的 ROS 工作空间中执行，且源码目录包含有效的 ROS 包"
    exit 1
fi

echo "[信息] 提取到 ${#PACKAGES[@]} 个包，打包顺序如下:"
for i in "${!PACKAGES[@]}"; do
    echo "  $((i+1)). ${PACKAGES[$i]}"
done
echo ""

# 统计
TOTAL=${#PACKAGES[@]}
CURRENT=0

# 打包所有包
for pkg in "${PACKAGES[@]}"; do
    CURRENT=$((CURRENT + 1))
    echo "[进度] $CURRENT/$TOTAL: $pkg"
    
    # 检查包是否存在
    if [ ! -d "$SRC_DIR/$pkg" ]; then
        echo "[跳过] 包不存在: $pkg"
        continue
    fi
    
    # 打包
    if ! build_deb_package "$pkg"; then
        echo "[错误] 打包 $pkg 失败，脚本终止"
        exit 1
    fi
done

echo "========================================"
echo "所有包打包完成！"
echo "输出目录: $DEB_OUTPUT_DIR"
echo "生成的包列表:"
ls -lh "$DEB_OUTPUT_DIR/"
echo ""
echo "PACKAGES 相关的已安装功能包列表:"
for pkg in "${PACKAGES[@]}"; do
    deb_pkg_name="ros-${ROS_DISTRO}-${pkg//_/-}"
    dpkg -l | grep "^ii  $deb_pkg_name " | awk '{printf "  %-40s %s\n", $2, $3}'
done
echo "========================================"
