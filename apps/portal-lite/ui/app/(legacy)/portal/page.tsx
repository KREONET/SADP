import { auth } from "@/auth";
import { Portal } from "@/components/portal";

export default async function Home() {
  const session = await auth();
  return <Portal session={session} />;
}
