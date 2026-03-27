# 阶段1: 获取静态 ffmpeg
FROM mwader/static-ffmpeg:6.1.1 AS ffmpeg-source
# 阶段2: 主镜像
FROM n8nio/runners:2.14.2
USER root


# 1. 复制 ffmpeg 静态二进制文件
COPY --from=ffmpeg-source /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-source /ffprobe /usr/local/bin/ffprobe

# 2. 直接在 runner 用户目录下创建字体目录并存放
# 既然没有 apk，我们就跳过系统安装，直接把文件放好
RUN mkdir -p /home/runner/fonts
COPY fonts/* /home/runner/fonts/

# 3. 安装 Python 库 (包含 Pillow, numpy 等)
# uv 应该是镜像自带的工具，之前的步骤证明它可以运行
RUN cd /opt/runners/task-runner-python && uv pip install numpy pandas requests Pillow openpyxl xlsxwriter xlrd

# 4. 复制配置文件
COPY n8n-task-runners.json /etc/n8n-task-runners.json

# 5. 确保权限正确
RUN chown -R runner:runner /home/runner/fonts

# 切换回 runner 用户
USER runner
WORKDIR /home/runner