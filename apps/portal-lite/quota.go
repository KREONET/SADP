package main

import (
	"errors"
	"strconv"
	"strings"
)

// userQuota는 사용자 1인이 동시에 점유할 수 있는 상한이다. 대시보드 사용량 막대,
// 신규 앱 위저드, 서버 검증이 서로 다른 숫자를 보면 "UI는 통과했는데 배포가 막히는"
// 상황이 생기므로 값은 여기서만 정의하고 /api/v1/catalog로 UI에 내려준다.
type userQuota struct {
	CPU    string `json:"cpu"`
	Memory string `json:"memory"`
}

const (
	// 사용자당 기본 상한. 네임스페이스 ResourceQuota와 같은 값을 써야 한다.
	defaultUserQuotaCPU    = "3"
	defaultUserQuotaMemory = "5Gi"

	// 한 앱이 만들 수 있는 Pod 수 상한. 차트 values 스키마와 같은 값이다.
	maxAppReplicas = 5
)

var configuredUserQuota = userQuota{
	CPU:    configured("PORTAL_USER_QUOTA_CPU", defaultUserQuotaCPU),
	Memory: configured("PORTAL_USER_QUOTA_MEMORY", defaultUserQuotaMemory),
}

var errQuantity = errors.New("해석할 수 없는 수량 표기")

// parseNonNegativeFloat는 "1", "1.5"만 허용한다. ParseFloat가 받아주는
// "1e9", "+1", "Inf", "NaN", 공백 낀 표기는 Kubernetes 수량 표기가 아니므로
// 여기서 막는다. UI와 서버가 같은 값을 봐야 하기 때문에 관대하게 굴지 않는다.
func parseNonNegativeFloat(text string) (float64, error) {
	if text == "" {
		return 0, errQuantity
	}
	dots := 0
	for _, char := range text {
		switch {
		case char >= '0' && char <= '9':
		case char == '.':
			dots++
			if dots > 1 {
				return 0, errQuantity
			}
		default:
			return 0, errQuantity
		}
	}
	amount, err := strconv.ParseFloat(text, 64)
	if err != nil || amount < 0 {
		return 0, errQuantity
	}
	return amount, nil
}

// parseCPUMilli는 "500m", "1", "1.5"를 millicore로 바꾼다.
// 부동소수 비교를 피하려고 정수 millicore로만 다룬다.
func parseCPUMilli(value string) (int64, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return 0, errQuantity
	}
	if rest, found := strings.CutSuffix(trimmed, "m"); found {
		milli, err := strconv.ParseInt(rest, 10, 64)
		if err != nil || milli < 0 {
			return 0, errQuantity
		}
		return milli, nil
	}
	cores, err := parseNonNegativeFloat(trimmed)
	if err != nil {
		return 0, errQuantity
	}
	// 0.1 같은 값이 99가 되지 않도록 반올림한다.
	return int64(cores*1000 + 0.5), nil
}

// memorySuffixes는 큰 단위부터 봐야 "Mi"가 "M"으로 잘리지 않는다.
var memorySuffixes = []struct {
	suffix string
	factor int64
}{
	{"Ki", 1 << 10}, {"Mi", 1 << 20}, {"Gi", 1 << 30}, {"Ti", 1 << 40},
	{"K", 1000}, {"M", 1000 * 1000}, {"G", 1000 * 1000 * 1000}, {"T", 1000 * 1000 * 1000 * 1000},
}

// parseMemoryBytes는 "512Mi", "5Gi", "2G", "1073741824"를 byte 수로 바꾼다.
func parseMemoryBytes(value string) (int64, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return 0, errQuantity
	}
	for _, unit := range memorySuffixes {
		rest, found := strings.CutSuffix(trimmed, unit.suffix)
		if !found {
			continue
		}
		amount, err := parseNonNegativeFloat(rest)
		if err != nil {
			return 0, errQuantity
		}
		return int64(amount*float64(unit.factor) + 0.5), nil
	}
	bytes, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil || bytes < 0 {
		return 0, errQuantity
	}
	return bytes, nil
}

// quotaUsage는 preset limit에 replicas를 곱한 총 점유량이다.
// 스케줄러가 보는 값이 limit이 아니라 request라도, 사용자에게 약속한 상한은
// "최대 얼마까지 쓸 수 있는가"이므로 limit 기준으로 계산한다.
func quotaUsage(preset resourcePreset, replicas int) (cpuMilli int64, memoryBytes int64, err error) {
	if replicas < 1 {
		return 0, 0, errQuantity
	}
	cpuMilli, err = parseCPUMilli(preset.Limits["cpu"])
	if err != nil {
		return 0, 0, err
	}
	memoryBytes, err = parseMemoryBytes(preset.Limits["memory"])
	if err != nil {
		return 0, 0, err
	}
	return cpuMilli * int64(replicas), memoryBytes * int64(replicas), nil
}

// formatCPUMilli는 계산 결과를 사람이 읽는 표기로 되돌린다(1500 → "1500m").
func formatCPUMilli(milli int64) string {
	if milli%1000 == 0 {
		return strconv.FormatInt(milli/1000, 10)
	}
	return strconv.FormatInt(milli, 10) + "m"
}

// formatMemoryBytes는 Mi/Gi 중 나누어떨어지는 큰 단위를 고른다.
func formatMemoryBytes(bytes int64) string {
	if bytes >= 1<<30 && bytes%(1<<30) == 0 {
		return strconv.FormatInt(bytes/(1<<30), 10) + "Gi"
	}
	if bytes >= 1<<20 && bytes%(1<<20) == 0 {
		return strconv.FormatInt(bytes/(1<<20), 10) + "Mi"
	}
	return strconv.FormatInt(bytes, 10)
}

// exceedsUserQuota는 상한 초과 항목을 알려준다. 상한 문자열 자체가 잘못 설정된
// 경우(오타 등)에는 통과시키지 않고 err로 알려 배포 요청을 막는다.
func exceedsUserQuota(preset resourcePreset, replicas int) (cpuOver bool, memoryOver bool, err error) {
	usedCPU, usedMemory, err := quotaUsage(preset, replicas)
	if err != nil {
		return false, false, err
	}
	limitCPU, err := parseCPUMilli(configuredUserQuota.CPU)
	if err != nil {
		return false, false, err
	}
	limitMemory, err := parseMemoryBytes(configuredUserQuota.Memory)
	if err != nil {
		return false, false, err
	}
	return usedCPU > limitCPU, usedMemory > limitMemory, nil
}
