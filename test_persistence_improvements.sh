#!/bin/bash

# 测试持久化功能改进的验证脚本

echo "=========================================="
echo "  端口映射管理脚本持久化功能测试"
echo "=========================================="
echo

# 检查脚本语法
echo "1. 检查脚本语法..."
if bash -n port_mapping_manager.sh; then
    echo "✓ 脚本语法检查通过"
else
    echo "✗ 脚本语法检查失败"
    exit 1
fi

# 检查关键函数是否存在
echo
echo "2. 检查关键函数..."

functions_to_check=(
    "save_rules"
    "setup_systemd_service" 
    "create_restore_script"
    "install_persistence_package"
    "setup_fallback_persistence"
    "verify_persistence_config"
    "test_persistence_config"
    "check_and_fix_persistence"
)

for func in "${functions_to_check[@]}"; do
    if grep -q "^$func()" port_mapping_manager.sh; then
        echo "  ✓ 函数 $func 存在"
    else
        echo "  ✗ 函数 $func 不存在"
    fi
done

# 检查菜单选项
echo
echo "3. 检查菜单选项..."
if grep -q "12\. 测试持久化配置" port_mapping_manager.sh; then
    echo "  ✓ 测试持久化配置菜单项存在"
else
    echo "  ✗ 测试持久化配置菜单项不存在"
fi

if grep -q "12) test_persistence_config" port_mapping_manager.sh; then
    echo "  ✓ 测试持久化配置处理逻辑存在"
else
    echo "  ✗ 测试持久化配置处理逻辑不存在"
fi

# 检查systemd服务模板
echo
echo "4. 检查systemd服务配置..."
if grep -q "ExecStart=\$restore_script" port_mapping_manager.sh; then
    echo "  ✓ systemd服务使用恢复脚本"
else
    echo "  ✗ systemd服务配置可能有问题"
fi

# 检查恢复脚本模板
echo
echo "5. 检查恢复脚本模板..."
if grep -q "#!/bin/bash" port_mapping_manager.sh && grep -q "iptables-restore" port_mapping_manager.sh; then
    echo "  ✓ 恢复脚本模板存在"
else
    echo "  ✗ 恢复脚本模板可能有问题"
fi

# 检查fallback机制
echo
echo "6. 检查fallback机制..."
fallback_methods=("rc.local" "crontab" "if-up.d")
for method in "${fallback_methods[@]}"; do
    if grep -q "$method" port_mapping_manager.sh; then
        echo "  ✓ $method fallback机制存在"
    else
        echo "  ✗ $method fallback机制不存在"
    fi
done

echo
echo "=========================================="
echo "  测试完成"
echo "=========================================="
echo
echo "主要改进："
echo "• 修复了systemd服务的多ExecStart问题"
echo "• 创建了专用的恢复脚本"
echo "• 增加了发行版适配和持久化包安装"
echo "• 提供了多种fallback机制"
echo "• 添加了完整的持久化测试功能"
echo "• 增强了错误处理和用户指导"
echo
echo "建议测试："
echo "1. 在测试环境中运行脚本"
echo "2. 测试 '10. 永久保存当前规则' 功能"
echo "3. 测试 '12. 测试持久化配置' 功能"
echo "4. 重启系统验证规则是否自动恢复"