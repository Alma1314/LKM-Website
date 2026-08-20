# LKM 网站部署教程

本文档说明如何把 LKM 网站(前端 Astro + 后端 FastAPI)通过 nginx 统一入口部署到生产主机。

## 架构概览

单机 docker-compose 编排 9 个服务,nginx 为唯一对外入口:

| 服务 | 镜像 | 端口(对外) | 职责 |
|---|---|---|---|
| `nginx` | `nginx:1.27-alpine` | `80` / `443` | TLS 终止、HTTP→HTTPS 重定向、反代分流、gzip、静态缓存 |
| `certbot` | `certbot/certbot` | 无 | 申请与自动续期 Let's Encrypt 证书(webroot) |
| `astro` | `lkm-official-website:latest` | 仅内网 `4321` | 前端 SSR |
| `backend` | `lkm-service:latest` | 仅内网 `8000` | FastAPI + GraphQL |
| `worker` | `lkm-service:latest` | 无 | 默认任务队列(ARQ)。`python -m app.core.worker_default` |
| `worker-send` | `lkm-service:latest` | 无 | 发送队列 worker。`python -m app.core.worker_send` |
| `postgres` | `postgres:16-alpine` | 仅内网 `5432` | 后端数据库 |
| `redis` | `redis:7-alpine` | 仅内网 `6379` | 任务队列、共享限流 / 缓存(ARQ 队列、RPOPLPUSH 限流、RMW 语义) |
| `minio` | `minio/minio:latest` | 仅容器内 `9000`/`9001` | S3 兼容对象存储:文件库文件与成员头像 |

> `worker` / `worker-send` 与 `backend` 共用 `lkm-service:latest` 镜像,仅启动入口不同;
> 两者依赖 Redis + PostgreSQL,负责异步消费任务队列(节点事件推送、发送任务等)。

请求分流(443 端口):

```
浏览器 ──> nginx(443, TLS 终止)
              ├─ /api/      ──> backend:8000   (保持路径)
              ├─ /graphql   ──> backend:8000   (支持 WebSocket)
              ├─ /_astro/*  ──> astro:4321     (指纹静态资源, immutable 长缓存)
              └─ 其余       ──> astro:4321     (SSR)
```

后端 REST 前缀为 `/api/v1`,GraphQL 为 `/graphql`。nginx 用 Docker 内嵌 DNS(`resolver 127.0.0.11`)在运行时动态解析 `backend`/`astro`,不依赖启动期 DNS。

## 前置条件

- 一台有公网 IP 的 Linux 主机,防火墙放行 `80` 与 `443` 端口。
- 域名 `lkm.s12mc.xyz` 已解析到该主机 IP。
- 已安装 Docker 与 Docker Compose 插件(`docker compose version` 可正常输出)。

## 一、获取代码

三个仓库需按如下目录结构放置(根仓库为编排入口,两个子项目各自独立):

```
LKM-Website/                  # 根仓库(含 docker-compose.yml 与本教程)
├── docker-compose.yml
├── DEPLOYMENT.md
├── dev.bat / dev.ps1 / dev.sh
├── LKM-official-website/     # 前端仓库(含 nginx/ 配置、前端 Dockerfile)
└── LKM-service/              # 后端仓库(含后端 Dockerfile)
```

示例:

```sh
git clone https://github.com/Alma1314/LKM-Website.git
cd LKM-Website
git clone https://github.com/LKM-AHZ/LKM-official-website.git
git clone https://github.com/LKM-AHZ/LKM-service.git
```

## 二、配置环境变量

在根目录创建 `.env` 文件(compose 会自动读取,**此文件已被 .gitignore 忽略,不要提交**):

```sh
# 三个密钥必须为强随机值、互不相同(生产环境 LKM_ENV=production 会强制校验)
LKM_JWT_SECRET=<64 位以上随机串>
LKM_TOTP_ENCRYPTION_KEY=<64 位以上随机串>
LKM_VERIFICATION_CODE_PEPPER=<64 位以上随机串>

# PostgreSQL 数据库密码(必须设置)
POSTGRES_PASSWORD=<强随机密码>

# 可选:覆盖数据库用户名/库名(默认均为 lkm)
POSTGRES_USER=lkm
POSTGRES_DB=lkm

# Redis(compose 已默认指向 redis 服务,一般无需改动)
# 留空则后端回退到单机内存版限流(共享限流失效);生产建议保留 compose 默认值
# LKM_REDIS_URL=redis://redis:6379/0

# MinIO 对象存储(必须设置密码;文件库与成员头像均存于此)
MINIO_ROOT_PASSWORD=<强随机密码>
# 可选:MinIO 管理员账号(默认 lkmadmin)
# MINIO_ROOT_USER=lkmadmin
# 可选:S3 桶名/对象 key 前缀(默认 lkm / files)
# LKM_S3_BUCKET=lkm
# LKM_S3_PREFIX=files

# 可选:GitHub OAuth 登录(不启用可留空)
LKM_GITHUB_CLIENT_ID=
LKM_GITHUB_CLIENT_SECRET=
```

生成随机密钥:

```sh
openssl rand -hex 48
```

> 若启用 GitHub OAuth,需在 GitHub App 后台把回调地址设为
> `https://lkm.s12mc.xyz/api/v1/auth/oauth/github/callback`。

## 三、构建并启动

```sh
cd LKM-Website
docker compose up -d --build
```

首次构建需拉取基础镜像与依赖,可能耗时数分钟。启动顺序由 `depends_on` 健康检查保证:先 `postgres`、`redis`、`minio` 就绪,再启动 `backend`(`worker`/`worker-send` 依赖 DB + Redis 同步拉起),`astro` 就绪后 `nginx` 再启动。

## 四、首次签发 HTTPS 证书

nginx 首次启动时没有正式证书,会用自签占位证书占位(保证能启动)。正式签发:

```sh
docker compose run --rm --entrypoint certbot certbot certonly --webroot \
  -w /var/www/certbot -d lkm.s12mc.xyz

docker compose exec nginx nginx -s reload
```

签发成功后证书落在 `certbot_conf` 卷(`/etc/letsencrypt`),reload 后 443 端口即使用正式证书。

## 五、验证

```sh
# 首页
curl -I https://lkm.s12mc.xyz/

# HTTP 应 301 到 HTTPS
curl -I http://lkm.s12mc.xyz/

# 后端健康检查
curl https://lkm.s12mc.xyz/api/v1/health
# 期望: {"code":0,"msg":"OK","data":{"status":"ok"}}

# GraphQL(示例查询)
curl -X POST https://lkm.s12mc.xyz/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ __typename }"}'

# 静态资源缓存头(应含 Cache-Control: public, immutable)
curl -I https://lkm.s12mc.xyz/_astro/<某资源路径>

# 成员头像(经 MinIO 存储代理端点,含 immutable 长缓存头)
curl -I https://lkm.s12mc.xyz/api/v1/avatars/<成员.webp>
# 期望: Cache-Control: public, max-age=31536000, immutable

# 证书链与有效期
openssl s_client -connect lkm.s12mc.xyz:443 </dev/null 2>/dev/null | openssl x509 -noout -dates
```

## 六、证书续期(自动)

- `certbot` 容器每 12 小时执行 `certbot renew`,证书文件原地更新。
- `nginx` 容器每 6 小时 `nginx -s reload`,自动拾取续期后的新证书。

无需人工干预;证书与续期状态都在 `certbot_conf` 卷,容器重建不丢。

## 七、常用运维

```sh
# 查看状态
docker compose ps

# 查看日志
docker compose logs -f nginx
docker compose logs -f backend
docker compose logs -f worker       # 任务队列消费
docker compose logs -f worker-send  # 发送队列

# 重启单个服务
docker compose restart backend

# MinIO Web 控制台(9001)仅在容器内网,未对外映射;需要浏览器访问时,
# 在 docker-compose.yml 的 minio 服务临时加 `ports: ['9001:9001']` 后 `docker compose up -d minio`,
# 访问 http://<主机IP>:9001,账号见 .env 的 MINIO_ROOT_USER/PASSWORD。或用镜像内置的 mc 命令行:
docker compose exec minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
docker compose exec minio mc ls local/lkm   # 列出默认桶内容

# 更新代码后重新构建并重启
git pull
docker compose up -d --build
```

## 数据库

### 默认方案：docker 内置 PostgreSQL

`docker compose up` 会自动拉取 `postgres:16-alpine` 镜像并启动;后端首次启动时通过 Alembic 自动建表,无需手动初始化。

连接数据库:

```sh
docker compose exec postgres psql -U lkm -d lkm
```

常用 SQL:

```sql
\dt          -- 列出所有表
\d users     -- 查看某张表结构
```

手动执行迁移(一般不需要,后端启动已自动执行):

```sh
docker compose exec backend alembic upgrade head
docker compose exec backend alembic current
```

备份与恢复:

```sh
# 备份
docker compose exec -T postgres pg_dump -U lkm lkm > backup_db_$(date +%F).sql

# 恢复
docker compose exec -T postgres psql -U lkm -d lkm < backup_db.sql
```

### 可选方案：主机手动安装 PostgreSQL

若需复用主机已有数据库实例,可在主机直接安装 PostgreSQL 并让后端连接外部库。

1. 安装并启动:

```sh
sudo apt update && sudo apt install -y postgresql postgresql-contrib
sudo systemctl enable --now postgresql
```

2. 建库建用户:

```sh
sudo -u postgres psql -c "CREATE USER lkm WITH PASSWORD '<强密码>';"
sudo -u postgres psql -c "CREATE DATABASE lkm OWNER lkm;"
```

3. 允许 Docker 容器连接:

- 编辑 `/etc/postgresql/*/main/postgresql.conf`,将 `listen_addresses` 改为 `'*'`。
- 在 `/etc/postgresql/*/main/pg_hba.conf` 末尾追加一行:

```
host all lkm 172.16.0.0/12 scram-sha-256
```

- 重启:

```sh
sudo systemctl restart postgresql
```

4. 修改 `docker-compose.yml`:删除 `postgres` 服务,并把 `backend` 的数据库连接指向宿主机:

```yaml
  backend:
    environment:
      LKM_DB_DRIVER: postgresql
      LKM_DB_HOST: 172.17.0.1   # 宿主机在 docker 网桥上的地址
      LKM_DB_PORT: 5432
      LKM_DB_NAME: lkm
      LKM_DB_USER: lkm
      LKM_DB_PASSWORD: <与建库时一致>
```

然后重新启动:

```sh
docker compose up -d backend
```

> docker 内置库零配置、随仓库走、备份简单,推荐默认使用;主机手动安装适用于复用已有数据库实例或需要更细管控的场景。

## 数据持久化

- 数据库在 `postgres_data` 卷(postgres 容器 `/var/lib/postgresql/data`)。
- Redis 在 `redis_data` 卷(redis 容器 `/data`,已开启 AOF `appendonly yes`;内容多为可重建的限流/缓存数据,一般无需单独备份)。
- 文件库上传文件与成员头像存在 **MinIO** 对象存储(`minio_data` 卷);后端以 S3 兼容接口读写。
- 博客 git 仓库(`blog_repos/`)在 `backend_data` 卷,挂载到后端容器 `/data`(`files_store` 为存量迁移源,运行时不写)。
- 备份示例:

```sh
# 数据库
docker compose exec postgres pg_dump -U lkm lkm > backup_db_$(date +%F).sql

# MinIO 对象(含文件库与头像)
docker compose exec minio sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mirror --preserve m/lkm ./minio_backup_$(date +%F)'

# 后端卷(博客 git 仓库)
docker run --rm -v lkm_backend_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/backend_files_$(date +%F).tar.gz -C /data .
```

## 迁移存量到 MinIO

首次从「本地磁盘存储」切换到 MinIO 时,若本地已有存量,在**切换前**(`LKM_STORAGE_BACKEND=s3` 生效前)执行一次性迁移脚本把本地数据搬进 MinIO(幂等,空数据安全跳过):

```sh
cd LKM-service
# 需先配好指向 MinIO 的 LKM_STORAGE_BACKEND=s3 及 s3_* 连接参数
./.venv/Scripts/python.exe -m scripts.migrate_files_to_s3       # 文件库存量
./.venv/Scripts/python.exe -m scripts.migrate_avatars_to_s3     # 预置成员头像
```

## 常见问题

- **后端反复重启(Exited 3)**:通常是密钥缺失或过短。确认 `.env` 中三个密钥已设置为强随机值,并 `docker compose up -d` 重读。
- **上传大文件被拒**:nginx 已设 `client_max_body_size 100m`,与后端 100MB 上限对齐;更大文件需同时改 nginx 配置与后端 `max_upload_bytes`。
- **数据库**:使用 PostgreSQL(`postgres:16-alpine` 服务,卷持久化)。后端经 `LKM_DB_*` 环境变量以 `postgresql+asyncpg` 连接;首次启动时 alembic 自动建表。
- **换域名/子路径**:需同步改 nginx 配置的 `server_name`、证书签发域名,以及前端 `PUBLIC_SITE_URL` / `PUBLIC_BASE_PATH`。
