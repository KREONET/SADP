/** 화면 6(구성 분류기, `/deployments/env-classifier`) 문구. */

export const ko = {
  metaTitle: "구성 분류기",
  eyebrow: "환경 변수 관리 도구",
  title: "구성 분류기",
  descriptionLine1:
    "환경 변수를 손쉽게 파싱하여 표준 ConfigMap 또는 보안이 강화된 OpenBao Secret으로 분류하세요.",
  descriptionLine2:
    "키를 드래그 앤 드롭하거나 자동 제안 기능을 활용하면 배포 전 민감한 데이터를 올바르게 처리할 수 있습니다.",

  /* 좌: 원문 입력 */
  rawInputTitle: "Raw .env 입력",
  loadFile: "파일 불러오기",
  fileInputLabel: ".env 파일 불러오기",
  rawTextLabel: "환경 변수 원문",
  rawPlaceholder:
    "키=값 형식으로 붙여 넣으세요...\nDB_HOST=postgres.shared-services.svc\nDB_PASSWORD=change-me\nAPI_KEY=sk_test_12345",
  clear: "지우기",
  parseAndClassify: "파싱 · 자동 분류",

  /* 좌: 미분류 */
  unclassifiedTitle: "미분류 변수",
  allClassified: "모든 변수가 분류되었습니다.",
  itemCount: "{count}개",

  /* 우: 분류 버킷 */
  configMapTitle: "ConfigMap",
  configMapDescription: "민감하지 않은 설정 데이터를 담습니다.",
  openbaoTitle: "OpenBao Secrets",
  openbaoDescription: "민감한 자격 증명을 위한 암호화된 저장소.",
  dropKeysHere: "여기로 키를 끌어다 놓으세요",
  dropSensitiveKeysHere: "민감한 키를 여기로 끌어다 놓으세요",
  saveClassifications: "분류 저장",

  /* 행 조작 */
  zoneUnclassified: "미분류",
  moveTo: "{zone}로",
  revealValue: "{key} 값 보기",
  hideValue: "{key} 값 가리기",
  unclassify: "{key} 분류 해제",
  deleteVariable: "{key} 목록에서 삭제",

  /* 결과 모달 */
  resultUnclassifiedTitle: "아직 분류할 변수가 남았습니다",
  resultUnclassified:
    "미분류 변수 {count}개가 남아 있습니다. 모두 분류해 주세요.",
  resultTitle: "분류 결과",
  resultSummary:
    "ConfigMap {configmap}개 / OpenBao Secret {openbao}개로 분류했습니다.",
  resultSavedNote:
    "배포 초안에 담았습니다. 새 앱 만들기에서 그대로 신청하면 ConfigMap으로 배포됩니다.",
  // 목록을 비우고 저장하는 것이 초안에서 환경변수를 빼는 방법이다. 저장할 때마다
  // 전체를 교체하므로, 빈 목록을 저장하면 이전에 담아 둔 값이 사라진다.
  resultClearedNote: "배포 초안에서 환경변수를 모두 비웠습니다.",
  // OpenBao 로 분류한 값은 어디에도 저장하지 않는다. 그 사실을 여기서 말하지 않으면
  // "포털에 넣었으니 배포되겠지"라고 믿고 넘어가 배포 후에야 값이 비어 있는 것을 본다.
  resultSecretNote:
    "OpenBao로 분류한 값은 브라우저 저장소나 Git에 남지 않고 제출 시 앱 전용 경로에 저장됩니다. 이후에는 승인된 앱 구성원만 OpenBao에서 수정·삭제할 수 있습니다.",
  resultOpenBaoLink: "OpenBao 열기",
  resultGoToWizard: "새 앱 만들기로 이동",
  resultClose: "확인",
};

export const en: typeof ko = {
  metaTitle: "Config Classifier",
  eyebrow: "ENV MANAGEMENT TOOL",
  title: "Config Classifier",
  descriptionLine1:
    "Parse environment variables and sort them into a standard ConfigMap or a hardened OpenBao Secret.",
  descriptionLine2:
    "Drag and drop keys or use the auto-suggestion to make sure sensitive data is handled correctly before deployment.",

  rawInputTitle: "Raw .env Input",
  loadFile: "Load File",
  fileInputLabel: "Load a .env file",
  rawTextLabel: "Raw environment variables",
  rawPlaceholder:
    "Paste your key-value pairs here...\nDB_HOST=postgres.shared-services.svc\nDB_PASSWORD=change-me\nAPI_KEY=sk_test_12345",
  clear: "Clear",
  parseAndClassify: "Parse & Auto-Classify",

  unclassifiedTitle: "Unclassified",
  allClassified: "Every variable has been classified.",
  itemCount: "{count} Items",

  configMapTitle: "ConfigMap",
  configMapDescription: "For non-sensitive configuration data.",
  openbaoTitle: "OpenBao Secrets",
  openbaoDescription: "Encrypted storage for sensitive credentials.",
  dropKeysHere: "Drop keys here",
  dropSensitiveKeysHere: "Drop sensitive keys here",
  saveClassifications: "Save Classifications",

  zoneUnclassified: "Unclassified",
  moveTo: "To {zone}",
  revealValue: "Reveal {key} value",
  hideValue: "Hide {key} value",
  unclassify: "Unclassify {key}",
  deleteVariable: "Delete {key} from the list",

  resultUnclassifiedTitle: "Some variables are still unclassified",
  resultUnclassified:
    "{count} variable(s) are still unclassified. Please classify them all.",
  resultTitle: "Classification result",
  resultSummary:
    "Classified into ConfigMap {configmap} / OpenBao Secret {openbao}.",
  resultSavedNote:
    "Saved to your deployment draft. Submit it from New App and it is deployed as a ConfigMap.",
  resultClearedNote: "Cleared every environment variable from the deployment draft.",
  resultSecretNote:
    "OpenBao values are kept out of browser storage and Git, then written to the app-specific path on submission. Only approved app members can later edit or delete them in OpenBao.",
  resultOpenBaoLink: "Open OpenBao",
  resultGoToWizard: "Go to New App",
  resultClose: "OK",
};
