#!/bin/bash

# 设置错误时退出
set -e

# 定义输出文件路径
OUTPUT_YAML="/etc/filebeat/prospectors.d/prospector-new.yaml"

# 检查必要的环境变量
required_vars=("CONTAINER_NAME" "POD_IP" "POD_NAME" "POD_NAMESPACE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "错误: 环境变量 $var 未设置"
        exit 1
    fi
done

# 获取所有符合条件的环境变量
log_vars=$(env | grep -E '^ucp_logs_.*(?<!_tags)=' | cut -d= -f1)

# 计数器用于跟踪日志收集器
collector_count=0

# 处理每个日志变量
for var_name in $log_vars; do
    # 获取日志路径
    log_path="${!var_name}"
    
    # 获取索引名称（去掉ucp_logs_前缀）
    index_name="${var_name#ucp_logs_}"
    
    # 获取对应的tags变量
    tags_var="${var_name}_tags"
    tags_value="${!tags_var}"
    
    # 创建新的日志收集器配置
    collector_config="- type: log
  enabled: true
  paths:
      - $log_path
  scan_frequency: 10s
  fields_under_root: true
  fields:
      container_name: $CONTAINER_NAME
      containerd_container: $CONTAINER_NAME
      pod_ip: $POD_IP
      pod_name: $POD_NAME
      namespace_name: $POD_NAMESPACE
      index: $index_name"

    # 如果有tags，添加到fields中
    if [ ! -z "$tags_value" ]; then
        IFS=',' read -ra tag_pairs <<< "$tags_value"
        for pair in "${tag_pairs[@]}"; do
            IFS='=' read -r key value <<< "$pair"
            collector_config="$collector_config
      $key: $value"
        done
    fi

    # 添加其他必要的配置
    collector_config="$collector_config
  tail_files: false
  close_inactive: 2h
  close_eof: false
  close_removed: true
  clean_removed: true
  close_renamed: false
  multiline.pattern: '^[0-9]{4}-[0-9]{2}-[0-9]{2}|^[0-9]{2}-[a-zA-Z]{3}-[0-9]{4}'
  multiline.negate: true
  multiline.match: after"

    # 如果是第一个收集器，创建新文件
    if [ $collector_count -eq 0 ]; then
        echo "$collector_config" > "$OUTPUT_YAML"
    else
        # 否则追加到文件末尾
        echo -e "\n$collector_config" >> "$OUTPUT_YAML"
    fi

    ((collector_count++))
done

# 检查是否生成了任何配置
if [ $collector_count -eq 0 ]; then
    echo "警告: 没有找到符合条件的环境变量，未生成配置文件"
    exit 1
fi

echo "配置文件已生成: $OUTPUT_YAML" 
