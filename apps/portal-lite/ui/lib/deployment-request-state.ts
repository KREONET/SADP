import type {
  DeploymentResult,
  DeploymentStatus,
} from "@/types/domain";

/** Go 신청 상태를 대시보드의 STATUS/RESULT 표현으로 변환한다. */
export function deploymentRequestPresentation(state: string): {
  status: DeploymentStatus;
  result: DeploymentResult;
} {
  switch (state) {
    case "deployed":
      return { status: "Ready", result: "Success" };
    case "stopped":
      return { status: "Validated", result: "Success" };
    case "deleted":
      return { status: "Validated", result: "Deleted" };
    case "pr-open":
    case "merged":
      return { status: "MR Created", result: "Success" };
    case "failed":
      return { status: "Validated", result: "Failed" };
    case "pr-creating":
    case "building":
    case "deploying":
    case "stopping":
    case "starting":
    case "deleting":
      return { status: "Validated", result: "Pending" };
    default:
      // received 및 향후 추가될 중간 상태.
      return { status: "Validated", result: "Pending" };
  }
}
