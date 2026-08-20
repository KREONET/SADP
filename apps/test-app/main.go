package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"sort"
	"time"
)

type pageData struct {
	AppEnv     string
	Hostname   string
	Config     map[string]string
	SecretKeys []string
}

var page = template.Must(template.New("index").Parse(`<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SADP test app</title><style>
body{font-family:system-ui,sans-serif;max-width:760px;margin:4rem auto;padding:0 1rem;background:#f5f7fb;color:#18212f}
main{background:white;border-radius:16px;padding:2rem;box-shadow:0 12px 36px #23314d20}h1{margin-top:0}
dt{font-weight:700;margin-top:1rem}dd{margin:.25rem 0}code{background:#eef2f8;padding:.2rem .4rem;border-radius:4px}
.ok{color:#087f5b;font-weight:700}.note{color:#52606d}</style></head><body><main>
<p class="ok">RKE2 · Envoy Gateway · app-profile 정상</p><h1>테스트 애플리케이션</h1>
<dl><dt>Pod</dt><dd><code>{{.Hostname}}</code></dd><dt>Environment</dt><dd><code>{{.AppEnv}}</code></dd></dl>
<h2>ConfigMap 값</h2><ul>{{range $k,$v := .Config}}<li><code>{{$k}}</code> = <code>{{$v}}</code></li>{{end}}</ul>
<h2>Secret 주입 상태</h2><ul>{{range .SecretKeys}}<li><code>{{.}}</code> = <strong>present</strong> (값은 표시하지 않음)</li>{{else}}<li class="note">주입된 Secret 없음</li>{{end}}</ul>
<p class="note">민감값은 응답·로그에 기록하지 않습니다. <a href="/api/info">비민감 진단 JSON</a></p>
</main></body></html>`))

func headers(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
}

func snapshot() pageData {
	hostname, _ := os.Hostname()
	config := map[string]string{
		"APP_ENV":  os.Getenv("APP_ENV"),
		"LOG_LEVEL": os.Getenv("LOG_LEVEL"),
		"DB_HOST":   os.Getenv("DB_HOST"),
		"DB_PORT":   os.Getenv("DB_PORT"),
	}
	secretKeys := make([]string, 0, 2)
	for _, key := range []string{"API_TOKEN", "DB_PASSWORD"} {
		if value, present := os.LookupEnv(key); present && value != "" {
			secretKeys = append(secretKeys, key)
		}
	}
	sort.Strings(secretKeys)
	return pageData{AppEnv: config["APP_ENV"], Hostname: hostname, Config: config, SecretKeys: secretKeys}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		headers(w)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/api/info", func(w http.ResponseWriter, _ *http.Request) {
		headers(w)
		w.Header().Set("Content-Type", "application/json")
		data := snapshot()
		_ = json.NewEncoder(w).Encode(map[string]any{
			"appEnv": data.AppEnv, "hostname": data.Hostname, "config": data.Config,
			"secretKeysPresent": data.SecretKeys,
		})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		headers(w)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := page.Execute(w, snapshot()); err != nil {
			log.Printf("render error: %v", err)
		}
	})
	server := &http.Server{
		Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	log.Printf("test app listening on %s", server.Addr)
	log.Fatal(server.ListenAndServe())
}
