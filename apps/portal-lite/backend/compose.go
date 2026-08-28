package main

// Docker Compose 를 "입력 형식"으로만 읽는다.
//
// Compose 를 Kubernetes manifest 로 변환해서 그대로 적용하지 않는다(kompose 방식).
// 그렇게 하면 이 플랫폼의 검증·쿼터·네트워크 정책·Gateway 규칙을 전부 우회한다.
// 대신 Compose 를 읽어 AppGroup 하나와 서비스마다 AppProfile 하나를 만들고, 그 뒤는
// 기존 단일 앱 경로(Helm app-profile -> Forgejo PR -> Argo CD)를 그대로 탄다.
//
//	docker-compose.yml -> 파서 -> 검증 -> AppGroup + AppProfile[] -> 기존 파이프라인
//
// 포트를 듣는 서비스 하나는 Deployment + Service + NetworkPolicy 한 벌이 된다.
// 포트 없는 worker는 Kubernetes에 연결할 Service/수신 probe가 없으므로 Deployment와
// 양방향 NetworkPolicy만 만든다. 어느 쪽도 여러 Compose 서비스를 한 Pod에 몰아넣지 않는다.

import (
	"fmt"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// composeService는 Compose 파일에서 읽어낸, 우리가 실제로 쓰는 항목만 담는다.
type composeService struct {
	Name string `json:"name"`
	// Compose 빌드는 파이프라인 credential 격리를 보장할 수 없어 받지 않는다.
	// Image에는 검증된 고정 tag/digest의 prebuilt image만 들어온다.
	Image string `json:"image,omitempty"`
	// Port는 이 서비스가 듣는 컨테이너 포트다. Compose의 host 쪽 포트는 무시한다
	// (Kubernetes에서 host 포트를 여는 것은 이 플랫폼에서 허용하지 않는다).
	Port int `json:"port"`
	// Replicas는 Helm Deployment의 기본 replica를 보존한다. Compose에는 이 값을
	// 열지 않으며 0이면 기존 app-profile 기본값 1을 쓴다.
	Replicas int `json:"-"`
	// DependsOn은 Compose가 선언한 의존이다. 내부 연결 기본값을 제안하는 데만 쓴다.
	DependsOn []string `json:"dependsOn,omitempty"`
	// Volume은 검증된 Compose named volume 하나다. 이름은 Kubernetes에 직접 쓰지 않고,
	// 서비스 전용 PVC를 만들지와 승인된 mount path만 전달한다.
	Volume *composeVolume `json:"volume,omitempty"`
	// Config는 Helm import가 Deployment의 비민감 literal env를 보존할 때만 쓴다.
	// Compose environment는 분류가 불가능하므로 기존처럼 전부 거부한다.
	Config map[string]string `json:"-"`
}

type composeVolume struct {
	Name      string `json:"name"`
	MountPath string `json:"mountPath"`
}

// composeFile은 파싱 결과다. 의존 서비스가 먼저 오며 같은 단계는 이름순으로 고정한다.
type composeFile struct {
	Services []composeService `json:"services"`
	// Warnings는 무시한 항목을 사용자에게 알린다. 조용히 버리면 "적었는데 반영이 안 된다".
	Warnings []string `json:"warnings"`
}

// composeError는 어느 서비스의 무엇이 문제인지 그대로 화면에 보여줄 수 있는 오류다.
type composeError struct {
	Field   string
	Message string
}

func (e composeError) Error() string { return e.Field + ": " + e.Message }

// 보안상 절대 받아들이지 않는 Compose 키.
// 값이 무엇이든 거부한다 — "빈 값이면 통과"로 두면 우회 경로가 된다.
var forbiddenComposeKeys = map[string]string{
	"network_mode": "network_mode(host 등)는 노드 네트워크를 그대로 쓰므로 허용하지 않습니다.",
	"privileged":   "privileged 컨테이너는 허용하지 않습니다.",
	"cap_add":      "추가 Linux capability는 허용하지 않습니다.",
	"devices":      "호스트 장치 접근은 허용하지 않습니다.",
	"pid":          "호스트 PID 네임스페이스 공유는 허용하지 않습니다.",
	"ipc":          "호스트 IPC 네임스페이스 공유는 허용하지 않습니다.",
	"userns_mode":  "사용자 네임스페이스 변경은 허용하지 않습니다.",
	"security_opt": "security_opt는 허용하지 않습니다.",
	"sysctls":      "sysctl 변경은 허용하지 않습니다.",
	"extra_hosts":  "extra_hosts는 클러스터 DNS를 우회하므로 허용하지 않습니다.",
}

// 읽기는 하지만 Kubernetes 로 옮기지 않는 키. 사용자에게 경고로 알린다.
var ignoredComposeKeys = map[string]string{
	"restart":        "restart 정책은 Kubernetes가 관리하므로 무시합니다.",
	"container_name": "container_name은 Kubernetes Pod 이름과 맞지 않아 무시합니다.",
	"networks":       "Compose 네트워크 대신 AppGroup Namespace와 NetworkPolicy를 사용합니다.",
	"deploy":         "deploy 설정 대신 포털의 자원 preset과 Pod 수를 사용합니다.",
	"healthcheck":    "healthcheck 대신 AppGroup 서비스의 TCP 상태 확인을 사용합니다.",
	"logging":        "logging 드라이버 설정은 무시합니다.",
	"profiles":       "profiles는 무시하고 모든 서비스를 배포 대상으로 봅니다.",
}

var supportedComposeKeys = map[string]struct{}{
	"image": {}, "expose": {}, "ports": {}, "depends_on": {}, "environment": {}, "volumes": {},
}

var supportedComposeTopLevelKeys = map[string]struct{}{
	"services": {}, "version": {}, "name": {}, "networks": {}, "volumes": {},
}

var composeVolumeNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$`)

// parseCompose는 compose 문서를 읽어 우리가 쓰는 항목만 남긴다.
func parseCompose(document string) (composeFile, error) {
	root, err := parseYAMLSubset(document)
	if err != nil {
		return composeFile{}, composeError{Field: "compose", Message: err.Error()}
	}
	mapping, ok := yamlMap(root)
	if !ok {
		return composeFile{}, composeError{Field: "compose", Message: "최상위가 매핑이 아닙니다."}
	}
	declaredVolumes, err := composeTopLevelVolumes(mapping["volumes"])
	if err != nil {
		return composeFile{}, err
	}
	for key := range mapping {
		if _, supported := supportedComposeTopLevelKeys[key]; !supported {
			return composeFile{}, composeError{
				Field: "compose." + key, Message: "이 최상위 Compose 키는 지원하지 않습니다.",
			}
		}
	}
	rawServices, present := mapping["services"]
	if !present {
		return composeFile{}, composeError{Field: "compose.services", Message: "services 섹션이 없습니다."}
	}
	services, ok := yamlMap(rawServices)
	if !ok || len(services) == 0 {
		return composeFile{}, composeError{Field: "compose.services", Message: "서비스가 하나도 없습니다."}
	}
	if len(services) > maxGroupServices {
		return composeFile{}, composeError{
			Field:   "compose.services",
			Message: fmt.Sprintf("서비스는 최대 %d개까지 배포할 수 있습니다.", maxGroupServices),
		}
	}

	names := make([]string, 0, len(services))
	for name := range services {
		names = append(names, name)
	}
	// PR diff 와 화면 순서가 map 순회에 흔들리지 않게 이름순으로 고정한다.
	sort.Strings(names)

	parsed := composeFile{Services: make([]composeService, 0, len(names)), Warnings: []string{}}
	if _, declared := mapping["networks"]; declared {
		parsed.Warnings = append(parsed.Warnings, "최상위 networks: Compose 네트워크 대신 AppGroup Namespace와 NetworkPolicy를 사용합니다.")
	}
	seenNormalizedNames := make(map[string]string, len(names))
	for _, name := range names {
		service, warnings, err := parseComposeService(name, services[name], declaredVolumes)
		if err != nil {
			return composeFile{}, err
		}
		if original, duplicate := seenNormalizedNames[service.Name]; duplicate {
			return composeFile{}, composeError{
				Field:   "compose.services." + name,
				Message: fmt.Sprintf("%q와 정규화한 서비스 이름 %q가 중복됩니다.", original, service.Name),
			}
		}
		seenNormalizedNames[service.Name] = name
		parsed.Services = append(parsed.Services, service)
		parsed.Warnings = append(parsed.Warnings, warnings...)
	}
	// 하나의 Compose volume을 여러 Deployment가 함께 쓰면 RWO attach와 파일 잠금
	// 의미가 깨진다. 이 플랫폼은 서비스마다 독립 PVC를 만들므로 단독 소유만 허용한다.
	volumeOwners := make(map[string]string, len(declaredVolumes))
	for _, service := range parsed.Services {
		if service.Volume == nil {
			continue
		}
		if owner, exists := volumeOwners[service.Volume.Name]; exists {
			return composeFile{}, composeError{
				Field:   "compose.services." + service.Name + ".volumes",
				Message: fmt.Sprintf("named volume %q는 %s 서비스가 이미 사용합니다. 서비스마다 별도 volume을 선언하세요.", service.Volume.Name, owner),
			}
		}
		volumeOwners[service.Volume.Name] = service.Name
	}
	for name := range declaredVolumes {
		if _, used := volumeOwners[name]; !used {
			return composeFile{}, composeError{Field: "compose.volumes." + name, Message: "어느 서비스도 사용하지 않는 named volume입니다."}
		}
	}
	// depends_on 이 가리키는 서비스가 실제로 있는지 본다. 없으면 내부 연결 제안이 틀린다.
	known := make(map[string]struct{}, len(parsed.Services))
	for _, service := range parsed.Services {
		known[service.Name] = struct{}{}
	}
	for index := range parsed.Services {
		kept := make([]string, 0, len(parsed.Services[index].DependsOn))
		for _, dependency := range parsed.Services[index].DependsOn {
			if _, found := known[dependency]; !found {
				return composeFile{}, composeError{
					Field:   "compose.services." + parsed.Services[index].Name + ".depends_on",
					Message: dependency + " 서비스를 찾을 수 없습니다.",
				}
			}
			kept = append(kept, dependency)
		}
		parsed.Services[index].DependsOn = kept
	}
	ordered, err := topologicallyOrderedServices(parsed.Services)
	if err != nil {
		return composeFile{}, err
	}
	parsed.Services = ordered
	return parsed, nil
}

// topologicallyOrderedServices는 depends_on 대상을 먼저 저장·queue하도록 정렬한다.
// 순환 의존을 허용하면 어느 서비스도 먼저 준비될 수 있다는 보장이 없어 명시적으로 막는다.
func topologicallyOrderedServices(services []composeService) ([]composeService, error) {
	byName := make(map[string]composeService, len(services))
	names := make([]string, 0, len(services))
	for _, service := range services {
		byName[service.Name] = service
		names = append(names, service.Name)
	}
	sort.Strings(names)
	state := make(map[string]uint8, len(services))
	ordered := make([]composeService, 0, len(services))
	var visit func(string) error
	visit = func(name string) error {
		switch state[name] {
		case 1:
			return composeError{Field: "compose.services." + name + ".depends_on", Message: "depends_on 순환 의존은 지원하지 않습니다."}
		case 2:
			return nil
		}
		state[name] = 1
		dependencies := append([]string(nil), byName[name].DependsOn...)
		sort.Strings(dependencies)
		for _, dependency := range dependencies {
			if err := visit(dependency); err != nil {
				return err
			}
		}
		state[name] = 2
		ordered = append(ordered, byName[name])
		return nil
	}
	for _, name := range names {
		if err := visit(name); err != nil {
			return nil, err
		}
	}
	return ordered, nil
}

func parseComposeService(name string, raw any, declaredVolumes map[string]struct{}) (composeService, []string, error) {
	field := "compose.services." + name
	service := composeService{Name: strings.ToLower(strings.TrimSpace(name))}
	if len(service.Name) > 40 || !appNamePattern.MatchString(service.Name) {
		return service, nil, composeError{
			Field:   field,
			Message: "서비스 이름은 40자 이하의 소문자 DNS 이름이어야 합니다(Kubernetes Service 이름이 됩니다).",
		}
	}
	definition, ok := yamlMap(raw)
	if !ok {
		return service, nil, composeError{Field: field, Message: "서비스 정의가 매핑이 아닙니다."}
	}
	if _, present := definition["build"]; present {
		return service, nil, composeError{
			Field:   field + ".build",
			Message: "Compose build는 빌드 credential을 빌드 단계가 읽을 수 있어 지원하지 않습니다. 고정 tag/digest의 prebuilt image를 사용하세요.",
		}
	}
	warnings := make([]string, 0)
	for key, message := range forbiddenComposeKeys {
		if _, present := definition[key]; present {
			return service, nil, composeError{Field: field + "." + key, Message: message}
		}
	}
	for key, message := range ignoredComposeKeys {
		if _, present := definition[key]; present {
			warnings = append(warnings, name+": "+message)
		}
	}
	for key := range definition {
		if _, supported := supportedComposeKeys[key]; supported {
			continue
		}
		if _, forbidden := forbiddenComposeKeys[key]; forbidden {
			continue
		}
		if _, ignored := ignoredComposeKeys[key]; ignored {
			continue
		}
		return service, nil, composeError{
			Field: field + "." + key, Message: "이 Compose 서비스 키는 지원하지 않습니다.",
		}
	}
	sort.Strings(warnings)

	if image, present := definition["image"]; present {
		text, ok := yamlScalarString(image)
		if !ok || strings.TrimSpace(text) == "" {
			return service, warnings, composeError{Field: field + ".image", Message: "이미지 이름을 읽을 수 없습니다."}
		}
		service.Image = strings.TrimSpace(text)
	}
	if service.Image == "" {
		return service, warnings, composeError{
			Field:   field,
			Message: "고정 tag 또는 digest가 있는 image가 필요합니다.",
		}
	}

	port, err := composeServicePort(field, definition)
	if err != nil {
		return service, warnings, err
	}
	service.Port = port
	if port == 0 {
		warnings = append(warnings, name+": 포트가 없어 worker로 배포합니다(Service와 수신 probe는 만들지 않습니다).")
	}
	if volumes, present := definition["volumes"]; present {
		volume, volumeErr := composeServiceVolume(field, service, volumes, declaredVolumes)
		if volumeErr != nil {
			return service, warnings, volumeErr
		}
		service.Volume = volume
		warnings = append(warnings, name+": named volume을 플랫폼 RWO PVC로 배포합니다. 이 서비스를 삭제하면 PVC 데이터도 함께 삭제됩니다.")
	}
	sort.Strings(warnings)

	if dependsOn, present := definition["depends_on"]; present {
		names, err := composeDependsOn(field, dependsOn)
		if err != nil {
			return service, warnings, err
		}
		service.DependsOn = names
	}
	if _, present := definition["environment"]; present {
		// Compose 문서에는 각 값의 config/Secret 분류가 없다. 이름·값 regex로 Secret을
		// 추측하면 APP_VALUE 같은 평범한 key의 password가 Git ConfigMap으로 새므로,
		// 이 입력면은 fail-close한다. Secret은 서비스 설정의 secretKeys(값 없음)와
		// OpenBao 사전 seed로만 공급한다.
		return service, warnings, composeError{
			Field:   field + ".environment",
			Message: "Compose environment 값은 Git에 기록될 수 있어 지원하지 않습니다. Secret은 서비스별 OpenBao Secret key 이름으로 선언하세요.",
		}
	}
	return service, warnings, nil
}

// composeServicePort는 컨테이너가 듣는 포트를 고른다.
//
// expose 를 먼저 본다. ports 는 "호스트:컨테이너" 라서 호스트 쪽 숫자를 컨테이너 포트로
// 잘못 읽기 쉽다. Kubernetes 에서는 호스트 포트를 열지 않으므로 컨테이너 쪽만 쓴다.
func composeServicePort(field string, definition map[string]any) (int, error) {
	_, hasExpose := definition["expose"]
	_, hasPorts := definition["ports"]
	if hasExpose && hasPorts {
		return 0, composeError{
			Field: field, Message: "expose와 ports를 함께 지정할 수 없습니다. 컨테이너 포트 하나만 선언하세요.",
		}
	}
	if expose, present := definition["expose"]; present {
		items, ok := yamlStringList(expose)
		if !ok {
			return 0, composeError{Field: field + ".expose", Message: "expose 목록을 읽을 수 없습니다."}
		}
		if len(items) != 1 {
			return 0, composeError{Field: field + ".expose", Message: "서비스마다 expose 포트 하나만 지원합니다."}
		}
		if len(items) == 1 {
			first := strings.ToLower(strings.TrimSpace(items[0]))
			if strings.HasSuffix(first, "/udp") {
				return 0, composeError{Field: field + ".expose", Message: "UDP 서비스 포트는 지원하지 않습니다."}
			}
			first = strings.TrimSuffix(first, "/tcp")
			port, err := strconv.Atoi(first)
			if err != nil || port < 1 || port > 65535 {
				return 0, composeError{Field: field + ".expose", Message: "1~65535 범위의 포트를 지정하세요."}
			}
			return port, nil
		}
	}
	ports, present := definition["ports"]
	if !present {
		// 큐 소비자·배치 작업처럼 포트를 듣지 않는 정상적인 Compose 서비스다.
		// 이후 단계가 worker로 명시하고 Service/거짓 TCP probe를 만들지 않는다.
		return 0, nil
	}
	items, ok := yamlStringList(ports)
	if !ok || len(items) == 0 {
		return 0, composeError{Field: field + ".ports", Message: "ports 목록을 읽을 수 없습니다."}
	}
	if len(items) != 1 {
		return 0, composeError{Field: field + ".ports", Message: "서비스마다 ports 항목 하나만 지원합니다."}
	}
	first := strings.ToLower(strings.TrimSpace(items[0]))
	if strings.HasSuffix(first, "/udp") {
		return 0, composeError{Field: field + ".ports", Message: "UDP 서비스 포트는 지원하지 않습니다."}
	}
	if strings.Count(first, ":") > 0 && strings.Contains(first, "/") {
		first = first[:strings.Index(first, "/")]
	}
	first = strings.TrimSuffix(first, "/tcp")
	// "8080:80", "127.0.0.1:8080:80", "80" 모두 마지막 조각이 컨테이너 포트다.
	segments := strings.Split(first, ":")
	container := strings.TrimSpace(segments[len(segments)-1])
	if strings.Contains(container, "-") {
		return 0, composeError{
			Field:   field + ".ports",
			Message: "포트 범위는 지원하지 않습니다. 컨테이너 포트 하나만 지정하세요.",
		}
	}
	port, err := strconv.Atoi(container)
	if err != nil || port < 1 || port > 65535 {
		return 0, composeError{Field: field + ".ports", Message: "1~65535 범위의 컨테이너 포트를 지정하세요."}
	}
	return port, nil
}

// composeTopLevelVolumes는 플랫폼이 직접 동적 프로비저닝할 빈 named volume 선언만
// 받는다. external/name/driver/driver_opts는 기존 PVC 채택이나 임의 provisioner 선택
// 경로가 되므로 전부 거부한다.
func composeTopLevelVolumes(raw any) (map[string]struct{}, error) {
	declared := map[string]struct{}{}
	if raw == nil {
		return declared, nil
	}
	mapping, ok := yamlMap(raw)
	if !ok {
		return nil, composeError{Field: "compose.volumes", Message: "named volume 선언을 읽을 수 없습니다."}
	}
	for name, definition := range mapping {
		if !composeVolumeNamePattern.MatchString(name) {
			return nil, composeError{Field: "compose.volumes." + name, Message: "volume 이름 형식이 올바르지 않습니다."}
		}
		opts, ok := yamlMap(definition)
		if definition == nil {
			opts, ok = map[string]any{}, true
		}
		if !ok || len(opts) != 0 {
			return nil, composeError{
				Field:   "compose.volumes." + name,
				Message: "빈 named volume({})만 허용합니다. external/name/driver 옵션은 사용할 수 없습니다.",
			}
		}
		declared[name] = struct{}{}
	}
	return declared, nil
}

// composeServiceVolume은 짧은 `name:/container/path` 한 개만 받는다. bind/anonymous
// volume과 read-only 플래그를 추측해서 변환하지 않는다.
func composeServiceVolume(field string, service composeService, raw any, declared map[string]struct{}) (*composeVolume, error) {
	items, ok := yamlStringList(raw)
	if !ok || len(items) != 1 {
		return nil, composeError{Field: field + ".volumes", Message: "서비스마다 named volume 하나만 지원합니다(name:/container/path)."}
	}
	parts := strings.Split(items[0], ":")
	if len(parts) != 2 {
		return nil, composeError{Field: field + ".volumes", Message: "bind/anonymous mount와 mode 옵션은 허용하지 않습니다. name:/container/path 형식을 사용하세요."}
	}
	name := strings.TrimSpace(parts[0])
	target := strings.TrimSpace(parts[1])
	if _, found := declared[name]; !found {
		return nil, composeError{Field: field + ".volumes", Message: fmt.Sprintf("top-level volumes에 빈 named volume %q를 먼저 선언하세요.", name)}
	}
	if target == "" || !strings.HasPrefix(target, "/") || path.Clean(target) != target || target == "/" || strings.Contains(target, "..") {
		return nil, composeError{Field: field + ".volumes", Message: "mount 대상은 정규화된 절대 컨테이너 경로여야 합니다."}
	}
	imageRepository, _, _ := splitPrebuiltImage(service.Image)
	approved := "/data"
	switch path.Base(imageRepository) {
	case "postgres":
		approved = "/var/lib/postgresql/data"
	case "redis":
		approved = "/data"
	}
	if target != approved {
		return nil, composeError{
			Field:   field + ".volumes",
			Message: fmt.Sprintf("이 이미지의 승인된 영구 저장 경로는 %s 입니다. 임의 시스템 경로 mount는 허용하지 않습니다.", approved),
		}
	}
	return &composeVolume{Name: name, MountPath: target}, nil
}

func composeDependsOn(field string, value any) ([]string, error) {
	// 짧은 형태는 목록, 긴 형태는 {service: {condition: ...}} 매핑이다.
	if mapping, ok := yamlMap(value); ok {
		names := make([]string, 0, len(mapping))
		for name := range mapping {
			names = append(names, strings.ToLower(strings.TrimSpace(name)))
		}
		sort.Strings(names)
		return names, nil
	}
	items, ok := yamlStringList(value)
	if !ok {
		return nil, composeError{Field: field + ".depends_on", Message: "depends_on을 읽을 수 없습니다."}
	}
	names := make([]string, 0, len(items))
	for _, item := range items {
		names = append(names, strings.ToLower(strings.TrimSpace(item)))
	}
	sort.Strings(names)
	return names, nil
}
