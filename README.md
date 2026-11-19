# NGINX HTTP/3 + Lua 镜像

基于 NGINX 官方 Alpine 镜像，支持 HTTP/3（QUIC），默认包含 GeoIP2、NDK、Lua、njs 和 Brotli 动态模块。模块在 `nginx.conf` 顶层通过 `load_module` 启用。启用 Lua 时，先加载 NDK。使用 HTTP/3 时，需要配置 TLS 和 QUIC 监听，并在部署环境开放对应的 UDP 端口。[模块加载示例](tests/smoke-test.sh) · [NGINX HTTP/3 文档](https://nginx.org/en/docs/quic.html)

## 本地构建与验证

```sh
docker build --pull --no-cache -t nginx-quic-lua:local .
sh tests/smoke-test.sh nginx-quic-lua:local
```

可通过 `--build-arg 'ENABLED_MODULES=ndk lua'` 选择额外构建的模块。修改基础镜像的 NGINX 版本时，同时更新 `Dockerfile` 中的基础镜像摘要和对应 `pkg-oss` 源码归档 SHA-512 校验和。njs 由官方基础镜像提供。

## GitHub Actions

拉取请求、推送和定时任务都会构建并扫描镜像。定时任务每次重新构建，从 Alpine 仓库安装最新补丁。漏洞扫描报告可在对应运行的 Artifacts 中下载。镜像通过 HTTP/3 实测与漏洞检查后，才会执行适用的发布步骤。

推送到 `main`、推送 `v*.*.*` 标签和定时任务会向 GHCR 发布签名镜像。若为仓库配置 `DOCKER_USERNAME` 和 `DOCKER_PASSWORD` secrets，推送到 `main` 时也会更新 Docker Hub 的 [`conqu3r/nginx:latest`](https://hub.docker.com/r/conqu3r/nginx)。
