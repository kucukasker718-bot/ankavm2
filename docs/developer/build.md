# 本地构建

## 前端构建

```bash
cd frontend
npm install
npm run build
```

构建输出位于 `frontend/dist`。

## 后端构建

```bash
cd backend
go test ./...
go build -o ../build/clicd .
```

如果要打包嵌入式 Web 面板，需要先把前端构建产物同步到后端嵌入目录。

## 一键构建

项目根目录提供了构建脚本：

```bash
bash build.sh
```

该脚本用于串联前端构建、静态资源同步和 Go 二进制构建。

## 文档站构建

```bash
cd docs
npm install
npm run dev
npm run build
```

`npm run dev` 用于本地预览，`npm run build` 用于生成静态文档。
