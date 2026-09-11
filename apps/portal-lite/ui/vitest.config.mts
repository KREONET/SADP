import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Auth.js가 사용하는 Next의 확장자 없는 import를 Node의 ESM 로더 대신 Vite로 해석한다.
    server: { deps: { inline: [/next-auth/] } },
  },
});
