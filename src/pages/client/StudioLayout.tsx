import { createContext, useContext, useEffect, useState, type CSSProperties } from "react";
import { NavLink, Outlet, useLocation, useParams } from "react-router-dom";
import { CalendarCheck, House, ListBullets } from "@phosphor-icons/react";
import { useStudio, type Studio } from "../../data/public";
import { ErrorState, Loading } from "../../components/ui/States";
import { BookingSheet } from "../../components/booking/BookingSheet";

type Ctx = { studio: Studio; openBooking: (serviceId?: string | null) => void };
const StudioCtx = createContext<Ctx | null>(null);
export const useStudioCtx = () => {
  const c = useContext(StudioCtx);
  if (!c) throw new Error("StudioCtx");
  return c;
};

/** Общая оболочка студии: загрузка профиля, акцент из конфигурации, нижняя навигация, шторка записи. */
export function StudioLayout() {
  const { slug = "" } = useParams();
  const q = useStudio(slug);
  const { pathname } = useLocation();
  const isOwner = pathname.includes("/owner");
  const [booking, setBooking] = useState<{ open: boolean; serviceId?: string | null }>({ open: false });

  useEffect(() => {
    if (q.data) document.title = `${q.data.tenant.profile.name} — онлайн-запись`;
  }, [q.data]);

  // isPending, а не isLoading: пока повтор запроса приостановлен (вкладка в фоне, нет сети), показываем загрузку, а не пустую ошибку
  if (q.isPending) return <main className="wrap pad-top"><Loading label="Загружаем студию" rows={4} /></main>;
  if (q.error || !q.data) return <main className="wrap pad-top"><ErrorState error={q.error} onRetry={() => q.refetch()} /></main>;

  const studio = q.data;
  const style = { "--accent": studio.tenant.profile.accent } as CSSProperties;
  return (
    <StudioCtx.Provider value={{
      studio,
      // приостановленная студия: шторку записи не открываем, показываем плашку с телефоном вверху
      openBooking: (serviceId) => (studio.tenant.suspended ? window.scrollTo({ top: 0, behavior: "smooth" }) : setBooking({ open: true, serviceId })),
    }}>
      <div style={style} className={isOwner ? "owner-shell" : "client-shell"}>
        {studio.tenant.mode === "preview" && !isOwner && (
          <div className="preview-bar" role="note">Образец студии: демонстрационные данные, уведомления не отправляются</div>
        )}
        {studio.tenant.suspended && !isOwner && (
          <div className="preview-bar" role="note">Онлайн-запись временно недоступна. Позвоните: {studio.tenant.profile.phone}</div>
        )}
        <Outlet />
        {!isOwner && (
          <nav className="tabbar glass" aria-label="Навигация">
            <NavLink end to={`/s/${slug}/`} className="tab"><House weight="fill" /><span>Главная</span></NavLink>
            <NavLink to={`/s/${slug}/services`} className="tab"><ListBullets weight="bold" /><span>Услуги</span></NavLink>
            <NavLink to={`/s/${slug}/my`} className="tab"><CalendarCheck weight="fill" /><span>Моя запись</span></NavLink>
          </nav>
        )}
        <BookingSheet studio={studio} open={booking.open} initialServiceId={booking.serviceId} onClose={() => setBooking({ open: false })} />
      </div>
    </StudioCtx.Provider>
  );
}
