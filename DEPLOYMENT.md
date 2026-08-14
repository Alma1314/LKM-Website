# LKM 网站部署教程

本文档说明如何把 LKM 网站(前端 Astro + 后端 FastAPI)通过 nginx 统一入口部署到生产主机。

## 架构概览

单机 docker-compose 编排 4 个服务,nginx 为唯一对外入口:

| 服务 | 镜像 | 端口(对外) | 职责 |
|---|---|---|---|
| `nginx` | `nginx:1.27-alpine` | `80` / `443` | TLS 终止、HTTP→HTTPS 重定向、反代分流、gzip、静态缓存 |
| `certbot` | `certbot/certbot` | 无 | 申请与自动续期 Let's Encrypt 证书(webroot) |
| `astro` | `lkm-official-website:latest` | 仅内网 `4321` | 前端 SSR |
| `backend` | `lkm-service:latest` | 仅内网 `8000` | FastAPI + GraphQL |

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

示例(替换为你的实际仓库地址):

```sh
git clone <根仓库地址> LKM-Website
cd LKM-Website
git clone <前端仓库地址> LKM-official-website
git clone <后端仓库地址> LKM-service
```

## 二、配置环境变量

在根目录创建 `.env` 文件(compose 会自动读取,**此文件已被 .gitignore 忽略,不要提交**):

```sh
# 三个密钥必须为强随机值、互不相同(生产环境 LKM_ENV=production 会强制校验)
LKM_JWT_SECRET=<64 位以上随机串>
LKM_TOTP_ENCRYPTION_KEY=<64 位以上随机串>
LKM_VERIFICATION_CODE_PEPPER=<64 位以上随机串>

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

首次构建需拉取基础镜像与依赖,可能耗时数分钟。启动顺序由 `depends_on` 健康检查保证:先 `backend`、`astro`,就绪后 `nginx` 再启动。

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

# 重启单个服务
docker compose restart backend

# 更新代码后重新构建并重启
git pull
docker compose up -d --build
```

## 数据持久化

- 后端数据(SQLite 数据库、博客 git 仓库、上传文件)在 `backend_data` 卷,容器内挂载到 `/data`。
- 备份示例:

```sh
docker run --rm -v lkm_backend_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/backend_data_$(date +%F).tar.gz -C /data .
```

## 常见问题

- **后端反复重启(Exited 3)**:通常是密钥缺失或过短。确认 `.env` 中三个密钥已设置为强随机值,并 `docker compose up -d` 重读。
- **上传大文件被拒**:nginx 已设 `client_max_body_size 100m`,与后端 100MB 上限对齐;更大文件需同时改 nginx 配置与后端 `max_upload_bytes`。
- **数据库**:当前使用 SQLite(卷持久化)。如需 PostgreSQL,需另加 `postgres` 服务并配置 `LKM_DB_DRIVER=postgresql` 及连接参数(超出本教程默认范围)。
- **换域名/子路径**:需同步改 nginx 配置的 `server_name`、证书签发域名,以及前端 `PUBLIC_SITE_URL` / `PUBLIC_BASE_PATH`。
