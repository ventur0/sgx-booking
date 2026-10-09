import { useEffect, useId, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "@phosphor-icons/react";

/**
 * Нижняя шторка (bottom sheet).
 * - кнопка «Назад» телефона закрывает шторку (запись в history), а не уводит со страницы;
 * - фокус переходит в шторку и возвращается на кнопку, которая её открыла; Tab не выходит наружу;
 * - Esc закрывает; фон не прокручивается;
 * - клавиатура телефона не перекрывает поля (visualViewport → --kb);
 * - safe area снизу; без анимации, если человек отключил движение.
 */
export function Sheet({ open, onClose, title, children, footer, labelledBy }: {
  open: boolean; onClose: () => void; title: string; children: ReactNode; footer?: ReactNode; labelledBy?: string;
}) {
  const id = useId();
  const panel = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  useEffect(() => {
    if (!open) return;
    const opener = document.activeElement as HTMLElement | null;
    const marker = `sheet-${id}`;
    history.pushState({ ...(history.state ?? {}), sheet: marker }, "");
    const onPop = () => closeRef.current();
    window.addEventListener("popstate", onPop);

    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    requestAnimationFrame(() => panel.current?.querySelector<HTMLElement>("[data-autofocus], h2")?.focus());

    const vv = window.visualViewport;
    const onVV = () => {
      const kb = vv ? Math.max(0, window.innerHeight - vv.height - vv.offsetTop) : 0;
      panel.current?.style.setProperty("--kb", `${kb}px`);
    };
    vv?.addEventListener("resize", onVV);
    vv?.addEventListener("scroll", onVV);

    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        closeRef.current();
      }
      if (e.key === "Tab" && panel.current) {
        const f = panel.current.querySelectorAll<HTMLElement>('a[href],button:not([disabled]),input:not([disabled]),select,textarea,[tabindex="0"]');
        if (!f.length) return;
        const first = f[0], last = f[f.length - 1];
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
      }
    };
    document.addEventListener("keydown", onKey);

    return () => {
      window.removeEventListener("popstate", onPop);
      document.removeEventListener("keydown", onKey);
      vv?.removeEventListener("resize", onVV);
      vv?.removeEventListener("scroll", onVV);
      document.body.style.overflow = prevOverflow;
      // закрыли кнопкой, а не «Назад» — убираем свою запись из истории
      if (history.state?.sheet === marker) history.back();
      opener?.focus?.();
    };
  }, [open, id]);

  if (!open) return null;
  return createPortal(
    <div className="sheet-root">
      <div className="sheet-scrim" onClick={onClose} aria-hidden="true" />
      <div ref={panel} className="sheet" role="dialog" aria-modal="true" aria-labelledby={labelledBy ?? `${id}-t`}>
        <div className="sheet-grip" aria-hidden="true" />
        <div className="sheet-head">
          <h2 id={`${id}-t`} tabIndex={-1}>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Закрыть"><X weight="bold" /></button>
        </div>
        <div className="sheet-body">{children}</div>
        {footer && <div className="sheet-foot">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}
