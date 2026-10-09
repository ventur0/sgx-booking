import { useEffect, useRef, type ReactNode } from "react";

/**
 * Плавное появление раздела при прокрутке. В покое раздел всегда виден;
 * анимация проигрывается один раз, когда он въезжает в экран.
 * Если на устройстве отключены анимации, ничего не анимируем.
 */
export function Reveal({ children, className = "", id, as: Tag = "section", label }: {
  children: ReactNode; className?: string; id?: string; as?: "section" | "div"; label?: string;
}) {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) return;
    if (el.getBoundingClientRect().top < innerHeight) return; // уже на экране — не дёргаем
    const io = new IntersectionObserver(
      ([e]) => {
        if (e.isIntersecting) {
          el.classList.add("in");
          io.disconnect();
        }
      },
      { rootMargin: "0px 0px -8% 0px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return (
    <Tag ref={ref as never} id={id} aria-label={label} className={`reveal ${className}`}>
      {children}
    </Tag>
  );
}
