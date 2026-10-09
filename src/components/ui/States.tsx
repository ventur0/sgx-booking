import type { ReactNode } from "react";
import { WarningCircle } from "@phosphor-icons/react";
import { humanError } from "../../lib/errors";

/** Единые состояния сетевых экранов: загрузка, ошибка с повтором, пусто. */
export function Loading({ label = "Загружаем…", rows = 3 }: { label?: string; rows?: number }) {
  return (
    <div className="state" role="status" aria-live="polite">
      <span className="sr-only">{label}</span>
      {Array.from({ length: rows }, (_, i) => <div key={i} className="skeleton" style={{ width: `${92 - i * 14}%` }} />)}
    </div>
  );
}

export function ErrorState({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  return (
    <div className="state error" role="alert">
      <WarningCircle weight="fill" />
      <p>{humanError(error)}</p>
      {onRetry && <button className="btn small" onClick={onRetry}>Повторить</button>}
    </div>
  );
}

export function Empty({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="state empty">
      <p>{children}</p>
      {action}
    </div>
  );
}

export function Notice({ kind, children }: { kind: "ok" | "bad" | "warn" | "info"; children: ReactNode }) {
  return <div className={`notice ${kind}`} role={kind === "bad" ? "alert" : "status"}>{children}</div>;
}

export function Field({ id, label, error, hint, children, full }: { id: string; label: string; error?: string; hint?: string; children: ReactNode; full?: boolean }) {
  return (
    <div className={`field${full ? " full" : ""}`}>
      <label htmlFor={id}>{label}</label>
      {children}
      {hint && !error && <span className="hint">{hint}</span>}
      {error && <span className="err" id={`${id}-err`}>{error}</span>}
    </div>
  );
}
