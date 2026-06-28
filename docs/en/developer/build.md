# Local Build

## Frontend Build

```bash
cd frontend
npm install
npm run build
```

Build output is written to `frontend/dist`.

## Backend Build

```bash
cd backend
go test ./...
go build -o ../build/clicd .
```

To package the embedded web panel, sync the frontend build output into the backend embed directory first.

## One-command Build

The project root provides a build script:

```bash
bash build.sh
```

The script chains frontend build, static asset sync, and Go binary build.

## Docs Build

```bash
cd docs
npm install
npm run dev
npm run build
```

`npm run dev` starts a local preview, and `npm run build` generates static documentation.
