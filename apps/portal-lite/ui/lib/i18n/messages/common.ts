/**
 * 전 화면 공통 문구(상단 내비게이션, 헤더 아이콘, 푸터, 반복되는 버튼 라벨).
 *
 * ko 를 원본으로 두고 en 을 `typeof ko` 로 못박아서, 한쪽에만 키를 추가하면
 * 타입 체크에서 바로 걸리도록 한다.
 */

export const ko = {
  nav: {
    home: "홈",
    services: "서비스",
    myApps: "내 앱",
    deployments: "배포",
    newApp: "새 앱",
    docs: "문서",
  },
  header: {
    searchPlaceholder: "서비스 검색...",
    searchLabel: "서비스 검색",
    credentials: "자격 증명",
    notifications: "알림",
    account: "계정",
  },
  footer: {
    security: "보안",
    apiStatus: "API 상태",
    rightsReserved: "All rights reserved.",
    privacyPolicy: "개인정보 처리방침",
    termsOfService: "이용약관",
  },
  locale: {
    /** 토글 그룹 전체를 설명하는 aria-label */
    label: "표시 언어",
    ko: "한국어",
    en: "English",
    /** 스크린리더용 짧은 설명 */
    switchTo: "표시 언어 전환",
  },
  actions: {
    refresh: "새로고침",
    viewAll: "전체 보기",
    back: "돌아가기",
    cancel: "취소",
    save: "저장",
    close: "닫기",
    retry: "다시 시도",
  },
  meta: {
    title: "SADP · 사용자 포털",
    description: "SADP 사용자 포털",
  },
};

export const en: typeof ko = {
  nav: {
    home: "Home",
    services: "Services",
    myApps: "My Apps",
    deployments: "Deployments",
    newApp: "New App",
    docs: "Docs",
  },
  header: {
    searchPlaceholder: "Search services...",
    searchLabel: "Search services",
    credentials: "Credentials",
    notifications: "Notifications",
    account: "Account",
  },
  footer: {
    security: "Security",
    apiStatus: "API Status",
    rightsReserved: "All rights reserved.",
    privacyPolicy: "Privacy Policy",
    termsOfService: "Terms of Service",
  },
  locale: {
    label: "Display language",
    ko: "한국어",
    en: "English",
    switchTo: "Switch display language",
  },
  actions: {
    refresh: "Refresh",
    viewAll: "View All",
    back: "Back",
    cancel: "Cancel",
    save: "Save",
    close: "Close",
    retry: "Retry",
  },
  meta: {
    title: "SADP · User Portal",
    description: "SADP user portal",
  },
};
