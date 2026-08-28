package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
)

type fieldError struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

type problem struct {
	Type   string       `json:"type"`
	Title  string       `json:"title"`
	Status int          `json:"status"`
	Detail string       `json:"detail"`
	Errors []fieldError `json:"errors,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeProblem(w http.ResponseWriter, status int, problemType, title, detail string, validationErrors []fieldError) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(problem{
		Type: problemType, Title: title, Status: status, Detail: detail, Errors: validationErrors,
	})
}

func decodeAppProfile(w http.ResponseWriter, r *http.Request) (appProfileInput, bool) {
	var input appProfileInput
	ok := decodeJSONBody(w, r, &input)
	return input, ok
}

func decodeAppGroup(w http.ResponseWriter, r *http.Request) (appGroupInput, bool) {
	var input appGroupInput
	ok := decodeJSONBody(w, r, &input)
	return input, ok
}

func readAppGroupBody(w http.ResponseWriter, r *http.Request) (appGroupInput, []byte, bool) {
	var input appGroupInput
	raw, ok := decodeJSONBodyRaw(w, r, &input)
	return input, raw, ok
}

// decodeJSONBody는 본문 하나를 엄격하게 읽는다. 알 수 없는 필드를 거부하는 이유는,
// 오타 난 설정이 조용히 무시된 채 배포되는 것을 막기 위해서다.
func decodeJSONBody(w http.ResponseWriter, r *http.Request, target any) bool {
	_, ok := decodeJSONBodyRaw(w, r, target)
	return ok
}

// decodeJSONBodyRaw는 멱등성 지문이 필요한 API를 위해 검증한 원문도 돌려준다.
func decodeJSONBodyRaw(w http.ResponseWriter, r *http.Request, target any) ([]byte, bool) {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeProblem(w, http.StatusUnsupportedMediaType,
			"urn:sadp:portal:problem:unsupported-media-type", "지원하지 않는 본문 형식",
			"Content-Type은 application/json이어야 합니다.", nil)
		return nil, false
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeProblem(w, http.StatusRequestEntityTooLarge,
				"urn:sadp:portal:problem:payload-too-large", "요청 본문 제한 초과",
				"JSON 요청은 64 KiB 이하여야 합니다.", nil)
			return nil, false
		}
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "요청 본문 읽기 실패",
			"요청을 다시 보내세요.", nil)
		return nil, false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeProblem(w, http.StatusRequestEntityTooLarge,
				"urn:sadp:portal:problem:payload-too-large", "요청 본문 제한 초과",
				"JSON 요청은 64 KiB 이하여야 합니다.", nil)
			return nil, false
		}
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "JSON 요청 해석 실패",
			"알 수 없는 필드 없이 하나의 올바른 JSON 객체를 보내세요.", nil)
		return nil, false
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "JSON 요청 해석 실패",
			"요청 본문에는 JSON 객체 하나만 허용합니다.", nil)
		return nil, false
	}
	return raw, true
}
