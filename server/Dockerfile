# AI-SAGA 审核网关 — 服务器 Docker 镜像（发布用）
#
# 说明：镜像里烘焙的 main.py 是"兜底/分发物"——平时容器用绑定挂载
#   -v /root/main.py:/code/main.py 盖住它；只有容器不带挂载启动时才用到镜像内的副本。
# 因此发布/上线前务必用 `./deploy_helper.sh release` 重建本镜像，保证镜像自带代码也是新版。
#
# 构建（由 deploy_helper.sh 的 build/release 子命令自动执行）：
#   docker build -t text-audit-service:latest .
FROM python:3.10-slim

WORKDIR /code

COPY requirements.txt /code/requirements.txt
RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt

COPY main.py /code/main.py

EXPOSE 8000
# 生产用多 worker；开发容器在 docker run 时覆盖为 --reload
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
