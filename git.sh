#!/usr/bin/env bash
# ====================================================
# 项目名称: Git Master 终端可视化管理脚本
# 运行环境: 适配 Android / Termux / MT 管理器终端环境
# 核心原则: 保护本地代码为主，提供直观的变更管理与推送控制
# ====================================================

# ================= 配置区 =================
# 您的专属 Github 仓库地址与日志绝对路径 (请勿随意修改)
MY_REPO_URL="https://github.com/cluntop/tvbox.git"
LOG_FILE="/data/data/bin.mt.plus/home/tvbox/.github/git.log"

# ================= 颜色与样式 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # 恢复默认配色

# ================= 基础核心函数 =================
# 自动创建日志所在目录，抑制报错输出
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# 统一日志记录器
log() {
    if [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    fi
}

# 格式化消息输出
success_msg() { echo -e "${GREEN}✔ $1${NC}"; log "成功: $1"; }
error_msg()   { echo -e "${RED}✘ $1${NC}"; log "错误: $1"; }
warn_msg()    { echo -e "${YELLOW}⚠ $1${NC}"; log "警告: $1"; }
info_msg()    { echo -e "${CYAN}ℹ $1${NC}"; }
title_msg()   { echo -e "\n${BOLD}${PURPLE}>>> $1 <<<${NC}\n"; }

# 依赖检查：验证 Git 是否已安装
check_git() {
    if ! command -v git > /dev/null 2>&1; then
        error_msg "致命错误: 未检测到 Git 环境，请先安装 Git。"
        exit 1
    fi
}

# 环境检查：验证当前目录是否为有效的 Git 仓库
check_git_repo() {
    if [ ! -d ".git" ]; then
        return 1
    fi
    return 0
}

# ================= 业务功能模块 =================

# 1. 增强版提交 (可视化 & 自定义信息) -> 遵守约定: 此步骤绝不自动拉取更新
enhanced_submit() {
    title_msg "🚀 提交与推送工作流"
    if ! check_git_repo; then error_msg "当前目录非 Git 仓库，请先执行 [6] 初始化"; return 1; fi

    local changes=$(git status --porcelain)
    if [ -z "$changes" ]; then
        warn_msg "当前工作区干净，没有任何文件被修改或新增，无需提交。"
        return 0
    fi

    echo -e "${YELLOW}待处理的文件变更概览:${NC}"
    git status --short
    echo ""

    # 捕获用户自定义提交信息，提供默认值以支持快速回车跳过
    read -p "📝 输入提交信息 (直接回车默认: Update Up): " msg
    [ -z "$msg" ] && msg="Update Up"

    info_msg "1/3 正在执行追踪关联 (git add .) ..."
    git add .

    info_msg "2/3 正在生成本地提交快照 (git commit) ..."
    git commit -m "$msg"

    # 获取当前所在分支，规避游离分支风险
    local curr=$(git branch --show-current)
    [ -z "$curr" ] && curr="main"

    info_msg "3/3 尝试标准推送至 origin/$curr ..."
    if git push origin "$curr"; then
        success_msg "推送成功！代码已同步至云端。"
    else
        warn_msg "标准推送受阻！远程仓库存在本地没有的代码 (fetch first)。"
        read -p "⚠ 是否无视冲突，执行暴力强制推送 (警告: 远程额外数据将被彻底覆盖)? (y/n): " force_push
        if [[ "$force_push" =~ ^[Yy]$ ]]; then
            info_msg "正在执行强推指令 (git push -f) ..."
            git push -f --set-upstream origin "$curr" && success_msg "强制推送成功！(远程状态已被本地覆盖)" || error_msg "强制推送失败，请检查网络拦截或写入权限。"
        else
            info_msg "已中止操作。建议排查远程变更或执行拉取合并。"
        fi
    fi
}

# 2. 增强版拉取 (附带冲突安全检测)
enhanced_pull() {
    title_msg "📥 拉取最新更新"
    if ! check_git_repo; then error_msg "当前目录非 Git 仓库"; return 1; fi

    local curr=$(git branch --show-current)
    [ -z "$curr" ] && curr="main"

    info_msg "1/2 正在静默探测远程最新状态 (git fetch)..."
    git fetch origin 2>/dev/null

    # 冲突阻断机制：防止覆盖本地未保存的心血
    local local_changes=$(git status --porcelain)
    if [ -n "$local_changes" ]; then
        warn_msg "高危操作拦截：检测到本地有未提交的代码，直接拉取极易产生代码污染或冲突！"
        read -p "是否自动暂存(stash)本地未提交的更改，然后再安全拉取? (y/n): " stash_choice
        if [[ "$stash_choice" =~ ^[Yy]$ ]]; then
            git stash
            info_msg "本地未提交更改已打包收入储藏区(stash)。"
        fi
    fi

    info_msg "2/2 正在执行代码下载与合并逻辑 (git pull origin $curr)..."
    if git pull origin "$curr" 2>&1; then
        success_msg "拉取合并圆满完成，本地库已同步至最新。"
    else
        error_msg "拉取失败，通常由于严重的结构树冲突或网络断联导致。"
        if [[ "$stash_choice" =~ ^[Yy]$ ]]; then
            warn_msg "补救提示：您刚才暂存的代码依然安全停留在 stash 中，排查完毕后请手动运行 'git stash pop' 恢复。"
        fi
    fi
}

# 3. 分支管理 (创建与跳转)
manage_branches() {
    title_msg "🌿 分支管理"
    if ! check_git_repo; then error_msg "当前目录非 Git 仓库"; return 1; fi
    
    echo -e "${CYAN}当前设备包含的所有分支详情:${NC}"
    git branch -a
    echo ""
    echo "1) 基于当前状态创建并切换至新分支"
    echo "2) 切换到已存在的其他分支"
    echo "3) 取消操作并返回主菜单"
    read -p "请选择分支指令: " b_choice
    case $b_choice in
        1) 
            read -p "请输入欲创建的新分支全称 (不能含空格): " b_name
            [ -n "$b_name" ] && git checkout -b "$b_name" && success_msg "成功！已切换并处在新分支: $b_name"
            ;;
        2) 
            read -p "请输入需要跳转的目标分支名称: " b_name
            [ -n "$b_name" ] && git checkout "$b_name" && success_msg "成功！工作区已切换至分支: $b_name"
            ;;
    esac
}

# 4. 可视化历史日志树状图
view_logs() {
    title_msg "📜 Git 提交历史溯源 (树状呈现)"
    if ! check_git_repo; then error_msg "当前目录非 Git 仓库"; return 1; fi
    # 限制显示最近 15 条，避免终端屏幕被刷爆
    git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit -n 15
    echo -e "\n"
}

# 5. 远端关联 (锚定仓库 URL)
bind_remote() {
    title_msg "🔗 绑定与修正远程仓库"
    check_git_repo || return 1
    local current_url=$(git remote get-url origin 2>/dev/null)
    
    echo -e "当前设备识别到的源地址: ${YELLOW}${current_url:-"[本地暂无配置远程源]"}${NC}"
    echo -e "脚本预设的强制目标地址: ${GREEN}$MY_REPO_URL${NC}"
    
    read -p "确认要将本地代码流指向预设目标地址吗? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        git remote remove origin 2>/dev/null
        git remote add origin "$MY_REPO_URL" && success_msg "绑定重置操作完成" || error_msg "指令拒绝，可能源名称冲突或权限不足"
    fi
}

# 6. 新仓库地基搭建
init_repo() {
    title_msg "📦 原始目录初始化仓库"
    if [ -d ".git" ]; then error_msg "阻止操作：当前目录已经是受 Git 监控的仓库"; return 1; fi
    # 兼容处理老版本 Git 将默认分支设为 master 的问题，强制更名为 main
    git init && git checkout -b main 2>/dev/null || git branch -M main
    success_msg "地基搭建完毕！当前所处分支已被统一规划为: main"
}

# 7. 工作区物理路径漫游
change_dir() {
    title_msg "📁 切换当前操作的系统物理目录"
    echo -e "当前系统位置: ${YELLOW}$(pwd)${NC}"
    read -p "请输入您想进入的新路径 (支持相对路径如 ../ 或绝对路径如 /sdcard/): " new_path
    if [ -n "$new_path" ]; then
        mkdir -p "$new_path" 2>/dev/null
        cd "$new_path" && success_msg "系统位置已成功转移至: $(pwd)" || error_msg "进入指定路径失败，请检查路径合法性与访问权限"
    fi
}

# 8. 无用对象深度回收清扫
deep_clean() {
    title_msg "🧹 .git 隐藏目录瘦身与垃圾回收"
    check_git_repo || return 1
    info_msg "正在清空历史动作残留 (reflog) 并执行激进的对象压缩 (aggressive gc)..."
    git reflog expire --expire=now --all 2>/dev/null
    git gc --prune=now --aggressive 2>/dev/null
    success_msg "瘦身成功！清理后的 .git 数据库空间占用缩减为: $(du -sh .git 2>/dev/null | cut -f1)"
}

# 9. 单独的定点推送功能
push_only() {
    title_msg "📤 单纯执行代码上云操作 (Push Only)"
    if ! check_git_repo; then error_msg "当前目录非 Git 仓库"; return 1; fi

    local curr=$(git branch --show-current)
    [ -z "$curr" ] && curr="main"

    info_msg "引擎启动，正在单独向 origin/$curr 推送数据包..."
    if git push origin "$curr"; then
        success_msg "数据包推送成功！"
    else
        warn_msg "推送通道受阻！远程服务器已包含您本地未拥有的提交版本 (fetch first)。"
        read -p "⚠ 危险选项：是否触发强制推送阀门，直接用本地数据摧毁并覆盖远程数据? (y/n): " force_push
        if [[ "$force_push" =~ ^[Yy]$ ]]; then
            info_msg "暴力覆盖协议启动 (git push -f) ..."
            git push -f --set-upstream origin "$curr" && success_msg "覆盖打击完成！远程数据已被强制重写。" || error_msg "覆盖打击失败，系统拦截了该操作。"
        else
            info_msg "强制覆盖指令已取消。"
        fi
    fi
}

# 10. 新增：细颗粒度审查 (状态与具体变更明细)
view_status() {
    title_msg "📊 库区状态剖析与代码变更明细雷达"
    if ! check_git_repo; then error_msg "当前目录非 Git 仓库，无法扫描"; return 1; fi

    echo -e "${CYAN}【当前文件级状态概览 (git status -s)】${NC}"
    # 显示简短状态：比如 M 代表被修改，?? 代表未追踪的新文件
    git status -s
    echo ""

    echo -e "${CYAN}【工作区尚未打包(未 add)的深层代码变动 (git diff)】${NC}"
    # 显示目前本地写了但还没 add 进暂存区的具体代码加减情况
    git diff
    echo ""

    echo -e "${CYAN}【已放入暂存区(已 add)待提交的代码变动 (git diff --cached)】${NC}"
    # 显示已经准备好，只要执行 commit 就会生成的代码加减情况
    git diff --cached
    echo ""

    echo -e "${CYAN}【回顾：上一条(最近一次)提交产生的最终影响 (git show --stat)】${NC}"
    # 调出最后一次成功执行 commit 时的文件增减统计报表
    git show --stat HEAD
    echo ""
}

# ================= 终端前端 GUI / 菜单仪表盘 =================
show_dashboard() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}          🛠️ Git Master 终端控制台核心          ${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
    
    echo -e " 📍 ${BOLD}物理坐标:${NC} ${YELLOW}$(pwd)${NC}"
    
    if check_git_repo; then
        local b_name=$(git branch --show-current 2>/dev/null)
        local changes=$(git status --porcelain 2>/dev/null | wc -l)
        local remote=$(git remote get-url origin 2>/dev/null || echo "未绑定远程")
        echo -e " 🌿 ${BOLD}当前分支:${NC} ${GREEN}${b_name:-"游离状态/未命名"}${NC}"
        echo -e " 🔗 ${BOLD}远程目标:${NC} ${CYAN}${remote}${NC}"
        if [ "$changes" -gt 0 ]; then
            echo -e " 📝 ${BOLD}变动预警:${NC} ${RED}检测到工作区存在 $changes 个未提交的变更文件${NC}"
        else
            echo -e " 📝 ${BOLD}变动预警:${NC} ${GREEN}工作区完全纯净，与仓库历史保持一致${NC}"
        fi
    else
        echo -e " ⚠️  ${BOLD}存储核心:${NC} ${RED}尚未建立本地 Git 数据库${NC}"
    fi
    echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"
    
    echo -e " ${GREEN}[1] 🚀 自动融合提交与推送 (Commit & Push)${NC}"
    echo -e " ${CYAN}[2] 📥 安全拉取与合并 (Fetch & Pull)${NC}"
    echo -e " ${YELLOW}[3] 📜 历史拓扑图溯源 (Log Graph)${NC}"
    echo -e " ${PURPLE}[4] 🌿 时间线分支跳转与构建 (Branch Mgt)${NC}"
    echo -e " ${BLUE}[5] 🔗 锚定固定远程目标源 (Bind Remote)${NC}"
    echo -e " ${CYAN}[6] 📦 从零初始化存储核心 (Init)${NC}"
    echo -e " ${YELLOW}[7] 📁 漂移工作目录系统路径 (Change Dir)${NC}"
    echo -e " ${RED}[8] 🧹 深度执行空间站垃圾回收 (GC & Clean)${NC}"
    echo -e " ${PURPLE}[9] 📤 单纯向服务器输送现有快照 (Push Only)${NC}"
    echo -e " ${GREEN}[10] 📊 雷达扫描: 状态剖析与变更明细 (Status & Diff)${NC}"
    echo -e " ${BOLD}[0] ❌ 脱离控制台 (Exit)${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
}

# ================= 权限前置防线 =================
if [ "$(id -u)" -ne 0 ]; then
    warn_msg "环境提示：未检测到 Root 权限，针对高安全级别目录操作可能会遭受系统拒绝..."
fi

# 在启动任何操作前检查基础二进制文件
check_git

# ================= 命令行外置参数解析路由器 (独立运行执行) =================
# 允许用户不通过界面，直接执行 ./git.sh status 或 ./git.sh push 等单一指令
if [ $# -gt 0 ]; then
    case "$1" in
        commit) enhanced_submit ;;
        pull)   enhanced_pull ;;
        log)    view_logs ;;
        branch) manage_branches ;;
        bind)   bind_remote ;;
        init)   init_repo ;;
        cd)     change_dir ;;
        clean)  deep_clean ;;
        push)   push_only ;;
        status) view_status ;;
        help|-h|--help)
            echo -e "${CYAN}Git Master CLI 独立模式使用指南:${NC}"
            echo -e "语法: $0 [选项]"
            echo -e "无参数执行时，自动进入可视化主菜单交互模式。\n"
            echo -e "独立运行指令："
            echo -e "  commit  : 执行代码添加、快照提交并推送到远端"
            echo -e "  pull    : 拉取最新的远程仓库版本并合并"
            echo -e "  log     : 渲染提交历史溯源图"
            echo -e "  branch  : 进入分支切换流"
            echo -e "  bind    : 将远程仓库地址绑定为脚本内配置项"
            echo -e "  init    : 创建新的本地仓库"
            echo -e "  cd      : (在独立模式下无效，由于 shell 进程沙盒机制)"
            echo -e "  clean   : 执行激进的无用数据清理"
            echo -e "  push    : 单独执行本地修改上云推送"
            echo -e "  status  : 打印当前修改详情及暂存区分析报表"
            ;;
        *) error_msg "无法识别的外部参数: $1。请输入 '$0 help' 查询使用说明。" ;;
    esac
    exit 0 # 执行完毕自动切断，保证独立单一运行
fi

# ================= 交互式生命周期循环 =================
while true; do
    show_dashboard
    read -p "👉 键入数字并回车，指派操作编号: " choice
    case $choice in
        1) enhanced_submit ;;
        2) enhanced_pull ;;
        3) view_logs ;;
        4) manage_branches ;;
        5) bind_remote ;;
        6) init_repo ;;
        7) change_dir ;;
        8) deep_clean ;;
        9) push_only ;;
        10) view_status ;;
        0) echo "操作结束，终端控制台已下线。"; exit 0 ;;
        *) error_msg "非法的选项指令，请确认您输入的数字属于面板编号范围" ;;
    esac
    echo ""
    read -p "Press Enter 确认并继续下一步任务流..."
done
