package main

// docker-compose 입력을 읽기 위한 최소 YAML 파서.
//
// Compose 입력은 전체 YAML 기능이 필요하지 않다. 의존성 파서로 허용 범위를 넓히는 대신
// "우리가 지원하는 부분집합만 읽고 나머지는 분명히 거부하는" 파서를 따로 둔다.
// Helm 렌더 결과는 Kubernetes 일반 YAML이므로 repository_import.go의 vendored 파서를 쓴다.
//
// 지원: 매핑, 시퀀스, 평문/따옴표 스칼라, 줄 주석, 문서 시작(---), 짧은 flow([] {}).
// 거부: anchor/alias(&, *), 태그(!), 블록 스칼라(|, >), 여러 문서, 탭 들여쓰기.
//
// 거부는 기능 부족이 아니라 안전장치다. 조용히 잘못 읽은 compose 는 사용자가 의도하지
// 않은 배포로 이어진다. 읽을 수 없으면 무엇을 못 읽었는지 줄 번호와 함께 알린다.

import (
	"fmt"
	"strconv"
	"strings"
)

const (
	maxYAMLBytes = 256 << 10
	maxYAMLLines = 4000
	maxYAMLDepth = 12
)

type yamlLine struct {
	number  int
	indent  int
	content string
}

// parseYAMLSubset은 문서 하나를 map/slice/string 트리로 읽는다.
// 모든 스칼라는 문자열로 남긴다. 숫자·불리언 해석은 사용하는 쪽에서 한다.
func parseYAMLSubset(input string) (any, error) {
	if len(input) > maxYAMLBytes {
		return nil, fmt.Errorf("YAML이 너무 큽니다(%d바이트 제한)", maxYAMLBytes)
	}
	lines, err := scanYAMLLines(input)
	if err != nil {
		return nil, err
	}
	if len(lines) == 0 {
		return nil, fmt.Errorf("내용이 없습니다")
	}
	value, next, err := parseYAMLBlock(lines, 0, lines[0].indent, 0)
	if err != nil {
		return nil, err
	}
	if next < len(lines) {
		return nil, fmt.Errorf("%d번째 줄: 들여쓰기가 맞지 않습니다", lines[next].number)
	}
	return value, nil
}

func scanYAMLLines(input string) ([]yamlLine, error) {
	raw := strings.Split(strings.ReplaceAll(input, "\r\n", "\n"), "\n")
	if len(raw) > maxYAMLLines {
		return nil, fmt.Errorf("YAML 줄 수가 너무 많습니다(%d줄 제한)", maxYAMLLines)
	}
	lines := make([]yamlLine, 0, len(raw))
	documents := 0
	for index, text := range raw {
		number := index + 1
		trimmed := strings.TrimSpace(text)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if trimmed == "---" {
			documents++
			if documents > 1 || len(lines) > 0 {
				return nil, fmt.Errorf("%d번째 줄: 문서 하나만 지원합니다", number)
			}
			continue
		}
		if trimmed == "..." {
			break
		}
		indent := len(text) - len(strings.TrimLeft(text, " "))
		if strings.ContainsRune(text[:indent], '\t') {
			return nil, fmt.Errorf("%d번째 줄: 들여쓰기에 탭을 쓸 수 없습니다", number)
		}
		if strings.HasPrefix(trimmed, "&") || strings.HasPrefix(trimmed, "*") {
			return nil, fmt.Errorf("%d번째 줄: anchor/alias는 지원하지 않습니다", number)
		}
		lines = append(lines, yamlLine{number: number, indent: indent, content: trimmed})
	}
	return lines, nil
}

// parseYAMLBlock은 indent 이상으로 들여쓰인 연속 블록 하나를 읽는다.
func parseYAMLBlock(lines []yamlLine, start, indent, depth int) (any, int, error) {
	if depth > maxYAMLDepth {
		return nil, start, fmt.Errorf("%d번째 줄: 중첩이 너무 깊습니다", lines[start].number)
	}
	if strings.HasPrefix(lines[start].content, "- ") || lines[start].content == "-" {
		return parseYAMLSequence(lines, start, indent, depth)
	}
	return parseYAMLMapping(lines, start, indent, depth)
}

func parseYAMLMapping(lines []yamlLine, start, indent, depth int) (any, int, error) {
	result := map[string]any{}
	index := start
	for index < len(lines) {
		line := lines[index]
		if line.indent < indent {
			break
		}
		if line.indent > indent {
			return nil, index, fmt.Errorf("%d번째 줄: 들여쓰기가 맞지 않습니다", line.number)
		}
		if strings.HasPrefix(line.content, "- ") {
			return nil, index, fmt.Errorf("%d번째 줄: 목록과 매핑을 같은 단계에 섞을 수 없습니다", line.number)
		}
		key, rest, err := splitYAMLKey(line)
		if err != nil {
			return nil, index, err
		}
		if _, duplicated := result[key]; duplicated {
			return nil, index, fmt.Errorf("%d번째 줄: key '%s' 가 중복되었습니다", line.number, key)
		}
		index++
		if rest != "" {
			scalar, err := parseYAMLScalar(line.number, rest)
			if err != nil {
				return nil, index, err
			}
			result[key] = scalar
			continue
		}
		// 값이 다음 줄부터 오는 경우. 더 깊게 들여쓰인 줄이 없으면 빈 값이다.
		if index >= len(lines) || lines[index].indent <= indent {
			result[key] = ""
			continue
		}
		child, next, err := parseYAMLBlock(lines, index, lines[index].indent, depth+1)
		if err != nil {
			return nil, next, err
		}
		result[key] = child
		index = next
	}
	return result, index, nil
}

func parseYAMLSequence(lines []yamlLine, start, indent, depth int) (any, int, error) {
	result := []any{}
	index := start
	for index < len(lines) {
		line := lines[index]
		if line.indent < indent {
			break
		}
		if line.indent > indent {
			return nil, index, fmt.Errorf("%d번째 줄: 들여쓰기가 맞지 않습니다", line.number)
		}
		if !strings.HasPrefix(line.content, "- ") && line.content != "-" {
			break
		}
		item := strings.TrimSpace(strings.TrimPrefix(line.content, "-"))
		index++
		if item == "" {
			if index >= len(lines) || lines[index].indent <= indent {
				result = append(result, "")
				continue
			}
			child, next, err := parseYAMLBlock(lines, index, lines[index].indent, depth+1)
			if err != nil {
				return nil, next, err
			}
			result = append(result, child)
			index = next
			continue
		}
		// "- key: value" 처럼 목록 항목이 곧바로 매핑을 여는 형태.
		if key, rest, ok := compactMappingKey(item); ok {
			entry := map[string]any{}
			if rest != "" {
				scalar, err := parseYAMLScalar(line.number, rest)
				if err != nil {
					return nil, index, err
				}
				entry[key] = scalar
			} else {
				entry[key] = ""
			}
			// 같은 항목의 나머지 key 들은 "- " 너비만큼 더 들여쓰여 있다.
			childIndent := indent + 2
			for index < len(lines) && lines[index].indent >= childIndent {
				if lines[index].indent != childIndent {
					return nil, index, fmt.Errorf("%d번째 줄: 들여쓰기가 맞지 않습니다", lines[index].number)
				}
				more, next, err := parseYAMLMapping(lines, index, childIndent, depth+1)
				if err != nil {
					return nil, next, err
				}
				for name, value := range more.(map[string]any) {
					if _, duplicated := entry[name]; duplicated {
						return nil, next, fmt.Errorf("%d번째 줄: key '%s' 가 중복되었습니다", lines[index].number, name)
					}
					entry[name] = value
				}
				index = next
			}
			result = append(result, entry)
			continue
		}
		scalar, err := parseYAMLScalar(line.number, item)
		if err != nil {
			return nil, index, err
		}
		result = append(result, scalar)
	}
	return result, index, nil
}

// compactMappingKey는 "key: value" 형태인지 본다. "8080:80" 같은 포트 문자열과
// 구분하려면 콜론 뒤 공백(또는 줄 끝)이 있어야 한다는 YAML 규칙을 그대로 쓴다.
func compactMappingKey(item string) (string, string, bool) {
	if strings.HasPrefix(item, "\"") || strings.HasPrefix(item, "'") {
		return "", "", false
	}
	position := strings.Index(item, ": ")
	if position < 0 {
		if !strings.HasSuffix(item, ":") {
			return "", "", false
		}
		position = len(item) - 1
	}
	key := strings.TrimSpace(item[:position])
	if key == "" || strings.ContainsAny(key, "{}[]") {
		return "", "", false
	}
	return key, strings.TrimSpace(item[position+1:]), true
}

func splitYAMLKey(line yamlLine) (string, string, error) {
	key, rest, ok := compactMappingKey(line.content)
	if !ok {
		return "", "", fmt.Errorf("%d번째 줄: 'key: value' 형태가 아닙니다", line.number)
	}
	if unquoted, err := unquoteYAMLScalar(key); err == nil {
		key = unquoted
	}
	return key, rest, nil
}

func parseYAMLScalar(number int, raw string) (any, error) {
	value := strings.TrimSpace(raw)
	switch {
	case value == "|" || value == ">" || strings.HasPrefix(value, "|-") || strings.HasPrefix(value, ">-"):
		return nil, fmt.Errorf("%d번째 줄: 블록 스칼라(|, >)는 지원하지 않습니다", number)
	case strings.HasPrefix(value, "!"):
		return nil, fmt.Errorf("%d번째 줄: 태그(!)는 지원하지 않습니다", number)
	case strings.HasPrefix(value, "&") || strings.HasPrefix(value, "*"):
		return nil, fmt.Errorf("%d번째 줄: anchor/alias는 지원하지 않습니다", number)
	case strings.HasPrefix(value, "["):
		return parseYAMLFlowSequence(number, value)
	case strings.HasPrefix(value, "{"):
		return parseYAMLFlowMapping(number, value)
	}
	if unquoted, err := unquoteYAMLScalar(value); err == nil {
		return unquoted, nil
	}
	// 따옴표 없는 값에서만 줄 주석을 떼어낸다(" #" 앞이 값이다).
	if position := strings.Index(value, " #"); position >= 0 {
		value = strings.TrimSpace(value[:position])
	}
	if value == "~" || value == "null" {
		return "", nil
	}
	return value, nil
}

func unquoteYAMLScalar(value string) (string, error) {
	if len(value) >= 2 && strings.HasPrefix(value, "\"") && strings.HasSuffix(value, "\"") {
		return strconv.Unquote(value)
	}
	if len(value) >= 2 && strings.HasPrefix(value, "'") && strings.HasSuffix(value, "'") {
		return strings.ReplaceAll(value[1:len(value)-1], "''", "'"), nil
	}
	return "", fmt.Errorf("따옴표로 감싸인 값이 아닙니다")
}

func parseYAMLFlowSequence(number int, value string) (any, error) {
	if !strings.HasSuffix(value, "]") {
		return nil, fmt.Errorf("%d번째 줄: 목록 괄호가 닫히지 않았습니다", number)
	}
	body := strings.TrimSpace(value[1 : len(value)-1])
	result := []any{}
	if body == "" {
		return result, nil
	}
	for _, part := range splitFlowItems(body) {
		item, err := parseYAMLScalar(number, part)
		if err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, nil
}

func parseYAMLFlowMapping(number int, value string) (any, error) {
	if !strings.HasSuffix(value, "}") {
		return nil, fmt.Errorf("%d번째 줄: 매핑 괄호가 닫히지 않았습니다", number)
	}
	body := strings.TrimSpace(value[1 : len(value)-1])
	result := map[string]any{}
	if body == "" {
		return result, nil
	}
	for _, part := range splitFlowItems(body) {
		key, rest, ok := compactMappingKey(part)
		if !ok {
			return nil, fmt.Errorf("%d번째 줄: '{key: value}' 형태가 아닙니다", number)
		}
		if unquoted, err := unquoteYAMLScalar(key); err == nil {
			key = unquoted
		}
		item, err := parseYAMLScalar(number, rest)
		if err != nil {
			return nil, err
		}
		result[key] = item
	}
	return result, nil
}

// splitFlowItems는 따옴표 안의 쉼표를 항목 구분자로 오인하지 않는다.
func splitFlowItems(body string) []string {
	items := make([]string, 0, 4)
	var current strings.Builder
	var quote rune
	for _, r := range body {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
			}
			current.WriteRune(r)
		case r == '"' || r == '\'':
			quote = r
			current.WriteRune(r)
		case r == ',':
			items = append(items, strings.TrimSpace(current.String()))
			current.Reset()
		default:
			current.WriteRune(r)
		}
	}
	if trimmed := strings.TrimSpace(current.String()); trimmed != "" {
		items = append(items, trimmed)
	}
	return items
}

/* ------------------------- 트리에서 값 꺼내는 도우미 ------------------------- */

func yamlMap(value any) (map[string]any, bool) {
	mapping, ok := value.(map[string]any)
	return mapping, ok
}

// yamlScalarString은 스칼라 값을 문자열로 꺼낸다.
// render.go 의 yamlString(YAML 출력용 인용)과 이름이 겹치지 않게 구분한다.
func yamlScalarString(value any) (string, bool) {
	text, ok := value.(string)
	return text, ok
}

// yamlStringList는 목록과 단일 스칼라를 모두 문자열 목록으로 돌려준다.
// compose 는 command/entrypoint 처럼 두 형태를 모두 허용한다.
func yamlStringList(value any) ([]string, bool) {
	switch typed := value.(type) {
	case nil:
		return nil, true
	case string:
		if typed == "" {
			return nil, true
		}
		return []string{typed}, true
	case []any:
		items := make([]string, 0, len(typed))
		for _, item := range typed {
			text, ok := item.(string)
			if !ok {
				return nil, false
			}
			items = append(items, text)
		}
		return items, true
	}
	return nil, false
}
