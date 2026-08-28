package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

// validateAPIListenAddress는 신원 헤더를 신뢰하는 Go API와 Next BFF가 같은 고정
// loopback 좌표를 쓰도록 한다. 임의 loopback port/IPv6도 보안상 외부 노출은 아니지만
// BFF와 갈라지면 배포 요청 전체가 502가 되므로 설정면을 열어 두지 않는다.
func validateAPIListenAddress(addr string) error {
	if addr != "127.0.0.1:8081" {
		return errors.New("PORTAL_API_ADDR는 Next BFF와 같은 127.0.0.1:8081이어야 합니다")
	}
	return nil
}

func run() error {
	addr := configured("PORTAL_API_ADDR", "127.0.0.1:8081")
	if err := validateAPIListenAddress(addr); err != nil {
		return err
	}
	logger := log.Default()
	api := &apiServer{}
	if baoClient, baoErr := newOpenBaoClient(openbaoAddress, openbaoCACert, openbaoJWTPath, openbaoWriterRole); baoErr != nil {
		logger.Printf("OpenBao 최초 Secret 저장 비활성: %v", baoErr)
	} else {
		api.openbao = baoClient
		logger.Printf("OpenBao 최초 Secret 저장 활성")
	}

	// 저장소를 열지 못하면(=PVC 미마운트/권한 오류) 신청 기능만 꺼둔 채로 뜬다.
	// 카탈로그·사전검증 같은 읽기 기능은 계속 제공해야 하므로 기동을 막지 않는다.
	requestStore, err := newStore(stateDir)
	if err != nil {
		logger.Printf("요청 저장소를 열지 못해 배포 요청 기능을 비활성화합니다: %v", err)
	} else {
		defer func() {
			if err := requestStore.close(); err != nil {
				logger.Printf("요청 저장소 닫기 실패: %v", err)
			}
		}()
		api.store = requestStore
		logger.Printf("요청 저장소 준비 완료: %s", stateDir)
	}

	forgejoConfig, forgejoReady := forgejoConfigFromEnv()
	if api.store != nil && forgejoReady {
		api.forgejo = newForgejoClient(forgejoConfig, api.store, logger)
		logger.Printf("Forgejo GitOps 연동 활성: owner=%s repo=%s branch=%s",
			forgejoConfig.Owner, forgejoConfig.Repo, forgejoConfig.TargetBranch)
	} else {
		logger.Printf("Forgejo 미설정: 배포 요청 API는 503을 돌려줍니다")
	}

	// 클러스터 안에서만 상태 프로브가 켜진다. 실패하면 카탈로그는 정적 상태를 쓴다.
	if kubeClient, kubeErr := newInClusterClient(); kubeErr != nil {
		logger.Printf("카탈로그 상태 프로브 비활성(정적 상태 사용): %v", kubeErr)
	} else {
		api.prober = newStatusProber(kubeClient)
		logger.Printf("카탈로그 상태 프로브 활성: ns=%s,%s,%s,%s",
			workloadNamespace, rancherNamespace, keycloakNamespace, openbaoNamespace)
		// 같은 kube 접속 정보로 빌드 파이프라인도 켠다. 클러스터 밖에서는 꺼진 채로 둔다.
		if api.forgejo != nil && autoApprove {
			api.forgejo.builder = newBuildPipeline(kubeClient, logger)
			// 같은 client로 앱별 ESO 권한도 만든다. 없으면 Secret을 쓴 앱은 배포돼도
			// ExternalSecret이 동기화되지 못한다.
			api.forgejo.openbao = api.openbao
			logger.Printf("자동 배포 파이프라인 활성: zone=%s build-ns=%s registry=%s",
				zoneID, buildNamespace, registryBase)
		}
	}
	// 이 worker는 PR 생성만 하는 수동 승인 큐가 아니다. 자동 병합 뒤 Argo 동기화와
	// Namespace 정리까지 한 상태 머신으로 처리하므로, 클러스터 client나 자동 승인이
	// 없는데 큐를 열면 CHANGE_ME 이미지가 든 PR과 끝나지 않는 삭제 요청만 남는다.
	// 읽기 API는 계속 제공하되 생성/삭제는 submissionEnabled가 503으로 닫게 한다.
	if api.forgejo != nil && (!autoApprove || api.forgejo.builder == nil) {
		logger.Printf("자동 배포 전제조건이 없어 배포 요청 API를 비활성화합니다: autoApprove=%t builder=%t",
			autoApprove, api.forgejo.builder != nil)
		api.forgejo = nil
	}

	// 종료 신호를 받으면 새 요청 수신을 멈추고 진행 중인 작업을 정리한다.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var workers sync.WaitGroup
	if api.forgejo != nil {
		workers.Add(2)
		go func() {
			defer workers.Done()
			api.forgejo.run(ctx)
		}()
		go func() {
			defer workers.Done()
			api.watchSourceUpdates(ctx)
		}()
		logger.Printf("Forgejo source branch 자동 갱신 활성: poll=%ds", sourcePollIntervalSeconds)
		// 재시작 전에 PR을 만들지 못한 요청을 다시 대기열에 올린다.
		resumed := 0
		for _, request := range api.store.resumable() {
			if err := api.forgejo.enqueue(request.ID); err != nil {
				logger.Printf("요청 %s 재개 실패: %v", request.ID, err)
				break
			}
			resumed++
		}
		if resumed > 0 {
			logger.Printf("미완료 요청 %d건을 재개합니다", resumed)
		}
	}

	server := &http.Server{
		Addr:              addr,
		Handler:           newHandler(api),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		// Git 저장소 자동 탐색은 파일 조회와 제한된 Helm 렌더를 포함한다. 10초면
		// 정상적인 사내 Forgejo 지연에도 응답이 중간에서 잘릴 수 있다.
		WriteTimeout:   45 * time.Second,
		IdleTimeout:    60 * time.Second,
		MaxHeaderBytes: 1 << 20,
	}

	serverErrors := make(chan error, 1)
	go func() {
		logger.Printf("%s %s listening on %s", serviceName, serviceVersion, server.Addr)
		listenErr := server.ListenAndServe()
		if errors.Is(listenErr, http.ErrServerClosed) {
			listenErr = nil
		}
		serverErrors <- listenErr
	}()

	select {
	case err := <-serverErrors:
		stop()
		workers.Wait()
		return err
	case <-ctx.Done():
		logger.Printf("종료 신호 수신: 진행 중인 요청을 정리합니다")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	shutdownErr := server.Shutdown(shutdownCtx)
	workers.Wait()
	<-serverErrors

	if shutdownErr != nil {
		return shutdownErr
	}
	logger.Printf("정상 종료 완료")
	return nil
}
