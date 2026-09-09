import type { Locale } from "@/lib/i18n/locale";

import * as admin from "@/lib/i18n/messages/admin";
import * as common from "@/lib/i18n/messages/common";
import * as compose from "@/lib/i18n/messages/compose";
import * as dashboard from "@/lib/i18n/messages/dashboard";
import * as envClassifier from "@/lib/i18n/messages/env-classifier";
import * as legacy from "@/lib/i18n/messages/legacy";
import * as myApps from "@/lib/i18n/messages/my-apps";
import * as newApp from "@/lib/i18n/messages/new-app";
import * as services from "@/lib/i18n/messages/services";

/**
 * 네임스페이스별 메시지 모듈을 하나의 사전으로 합친다.
 *
 * 네임스페이스를 파일로 쪼개 둔 이유는 화면 단위로 문구를 나눠 작업해도
 * 같은 파일을 동시에 건드리지 않게 하기 위해서다. 여기(조립 지점)만 고정되면
 * 개별 메시지 파일은 서로 독립적으로 커진다.
 */
const DICTIONARIES = {
  ko: {
    admin: admin.ko,
    common: common.ko,
    compose: compose.ko,
    dashboard: dashboard.ko,
    envClassifier: envClassifier.ko,
    legacy: legacy.ko,
    myApps: myApps.ko,
    newApp: newApp.ko,
    services: services.ko,
  },
  en: {
    admin: admin.en,
    common: common.en,
    compose: compose.en,
    dashboard: dashboard.en,
    envClassifier: envClassifier.en,
    legacy: legacy.en,
    myApps: myApps.en,
    newApp: newApp.en,
    services: services.en,
  },
} as const;

/**
 * ko 를 원본 타입으로 삼는다. 각 메시지 모듈이 `en: typeof ko` 로 선언돼 있어서
 * 어느 한쪽에만 키를 추가하면 그 파일에서 컴파일 에러가 난다.
 */
export type Dictionary = (typeof DICTIONARIES)["ko"];

export function getDictionary(locale: Locale): Dictionary {
  return DICTIONARIES[locale];
}
