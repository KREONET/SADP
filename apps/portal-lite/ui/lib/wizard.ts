import type { NewAppDraft, WizardStep } from "@/types/domain";

/**
 * 좌측 스테퍼 5단계. 제목/부제는 i18n 사전에서 오고, 여기서는 단계 수와
 * 정적 라우트 생성에만 쓰인다(스텝을 늘리면 사전 키 s1..sN도 함께 늘린다).
 */
export const WIZARD_STEPS: WizardStep[] = [
  { step: 1, title: "기본 정보", subtitle: "이름, 프로젝트" },
  { step: 2, title: "소스 정보", subtitle: "Git Repo, Branch" },
  { step: 3, title: "실행 조건", subtitle: "Port, Resource" },
  { step: 4, title: "접근·통신", subtitle: "외부 접속, 인증, 외부 통신" },
  { step: 5, title: "검토", subtitle: "설정 확인 후 신청" },
];

export const WIZARD_LAST_STEP = WIZARD_STEPS.length;

/**
 * 초기값. project·resourceSize는 카탈로그에서 와야 하므로 비워 둔다
 * (임의 기본값을 넣으면 서버에 없는 값을 고른 채 제출될 수 있다).
 */
export const EMPTY_DRAFT: NewAppDraft = {
  name: "",
  project: "",
  sourceMode: "git",
  repositoryUrl: "",
  branch: "main",
  dockerfilePath: "Dockerfile",
  image: "",
  port: "8080",
  resourceSize: "",
  replicas: "1",
  // 노출과 인증, 외부 통신은 서로 독립이다. 기본값은 예전 화면(Public)과 같은
  // "외부 URL + 인증 없음" 이되, 외부 통신만은 가장 좁은 blocked 로 시작한다.
  // 사용자가 고르지 않았는데 인터넷으로 나갈 수 있으면 안 된다.
  exposureMode: "external",
  authMode: "none",
  egressMode: "blocked",
  allowedCidrs: [],
  envVars: [],
};
