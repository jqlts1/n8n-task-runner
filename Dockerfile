# 阶段1: 获取静态 ffmpeg
FROM mwader/static-ffmpeg:6.1.1 AS ffmpeg-source

# 阶段2: 主镜像
FROM n8nio/runners:2.35.3

USER root

# 1. 复制 ffmpeg 静态二进制文件
COPY --from=ffmpeg-source /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-source /ffprobe /usr/local/bin/ffprobe
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe

# 2. 创建字体目录并复制字体文件
RUN mkdir -p /home/runner/fonts
# 使用 COPY 而不是通配符，避免构建上下文问题
COPY fonts /home/runner/fonts/

# 3. 安装 Python 库
# 添加错误处理和重试机制
WORKDIR /opt/runners/task-runner-python
RUN set -e && \
    echo "Installing Python packages..." && \
    uv pip install --no-cache-dir numpy pandas requests Pillow openpyxl xlsxwriter xlrd || \
    (echo "First attempt failed, retrying..." && sleep 2 && \
     uv pip install --no-cache-dir numpy pandas requests Pillow openpyxl xlsxwriter xlrd) || \
    (echo "Second attempt failed, trying with verbose output..." && \
     uv pip install --verbose numpy pandas requests Pillow openpyxl xlsxwriter xlrd)

# 4. 复制配置文件
COPY n8n-task-runners.json /etc/n8n-task-runners.json

# 5. 确保权限正确
RUN chown -R runner:runner /home/runner/fonts && \
    chmod -R 755 /home/runner/fonts

# 6. 设置 launcher 健康检查端口，避免与 runner 端口冲突
ENV N8N_RUNNERS_HEALTH_CHECK_SERVER_PORT=5684

# 7. 验证安装
RUN ffmpeg -version && \
    ffprobe -version && \
    ls -la /home/runner/fonts/ && \
    cat /etc/n8n-task-runners.json

# 切换回 runner 用户
USER runner
WORKDIR /home/runner

# 健康检查（可选）
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${N8N_RUNNERS_HEALTH_CHECK_SERVER_PORT}/healthz || exit 1
