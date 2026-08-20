import { redirect } from "next/navigation";

/** `/new-app` 진입은 항상 1단계로 보낸다. */
export default function NewAppIndexPage() {
  redirect("/new-app/1");
}
