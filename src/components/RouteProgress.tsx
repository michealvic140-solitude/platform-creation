import { useEffect, useState } from "react";
import { useRouterState } from "@tanstack/react-router";
import lslLogo from "@/assets/lsl-logo.png";

/**
 * Centered spinner overlay that shows while TanStack Router is loading
 * the next route. Has a safety timeout so it can never get stuck on
 * screen if a navigation signal is missed.
 */
export function RouteProgress() {
  const status = useRouterState({ select: (s) => s.status });
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    let hide: ReturnType<typeof setTimeout> | null = null;
    let safety: ReturnType<typeof setTimeout> | null = null;
    if (status === "pending") {
      setVisible(true);
      // Hard cap so the spinner can never stick on screen.
      safety = setTimeout(() => setVisible(false), 6000);
    } else {
      hide = setTimeout(() => setVisible(false), 160);
    }
    return () => {
      if (hide) clearTimeout(hide);
      if (safety) clearTimeout(safety);
    };
  }, [status]);

  if (!visible) return null;
  return (
    <div className="fixed inset-0 z-[200] pointer-events-none grid place-items-center bg-background/25 backdrop-blur-[1px]">
      <div className="relative h-16 w-16 rounded-full border border-primary/35 bg-background/70 p-2 shadow-gold">
        <span className="absolute inset-[-10px] rounded-full border border-primary/20" />
        <img
          src={lslLogo}
          alt="LSL loading"
          className="h-full w-full object-contain rounded-full animate-spin"
          style={{ animationDuration: "1.1s", filter: "drop-shadow(0 0 16px oklch(0.82 0.22 88 / 0.75))" }}
        />
      </div>
    </div>
  );
}