FROM alpine/helm:3.21.3 AS helm

FROM node:22.18.0-alpine3.22 AS frontend
WORKDIR /src
ENV NEXT_TELEMETRY_DISABLED=1
COPY ui/package.json ui/package-lock.json ./
RUN npm ci
COPY ui ./
# build-local-images.sh가 루트 .env에서 화이트리스트로 추린 공개값만 전달한다.
# 원본 .env와 서버용 Secret은 build context에 들어오지 않으며, 임시 파일도 이 단계에서 지운다.
ARG PORTAL_UI_PUBLIC_ENV_B64=""
RUN if [ -n "${PORTAL_UI_PUBLIC_ENV_B64}" ]; then \
      printf '%s' "${PORTAL_UI_PUBLIC_ENV_B64}" | base64 -d > .env.production.local; \
    fi && \
    npm run lint && npm run typecheck && npm test && npm run build && \
    rm -f .env.production.local

FROM golang:1.24.5-alpine3.22 AS api-build
WORKDIR /src
ENV GOPROXY=off \
    GOSUMDB=off \
    GOFLAGS=-mod=vendor
COPY --from=helm /usr/bin/helm /usr/local/bin/helm
COPY go.mod go.sum *.go openapi.yaml ./
# 테스트베드 빌더 Pod는 인터넷 egress를 전제로 하지 않는다. Helm 결과를 읽는 YAML
# 모듈은 검토한 소스를 함께 넣어 빌드가 공개 Go proxy 상태에 좌우되지 않게 한다.
COPY vendor ./vendor
RUN test -z "$(gofmt -l *.go)" && \
    go vet ./... && \
    go test ./... && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/portal-api ./

FROM node:22.18.0-alpine3.22
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8080
COPY --from=frontend --chown=10001:10001 /src/.next/standalone ./
COPY --from=frontend --chown=10001:10001 /src/.next/static ./.next/static
COPY --from=api-build --chown=10001:10001 /out/portal-api ./portal-api
COPY --from=helm /usr/bin/helm /usr/local/bin/helm
COPY --chown=10001:10001 entrypoint.sh ./entrypoint.sh
RUN rm -rf .next/cache && \
    ln -s /tmp/next-cache .next/cache && \
    chmod 0555 entrypoint.sh portal-api
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
