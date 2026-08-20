FROM golang:1.24.5-alpine3.22 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/test-app ./

FROM scratch
COPY --from=build /out/test-app /test-app
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/test-app"]
