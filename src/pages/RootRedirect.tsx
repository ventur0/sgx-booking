import { Navigate } from "react-router-dom";
import { Empty } from "../components/ui/States";

/** Корень сайта открывает студию по умолчанию (переменная DEFAULT_TENANT при сборке). */
export function RootRedirect() {
  if (!__DEFAULT_TENANT__) return <main className="wrap pad-top"><Empty>Откройте ссылку студии вида /s/название/, которую вам прислали.</Empty></main>;
  return <Navigate to={`/s/${__DEFAULT_TENANT__}/`} replace />;
}
