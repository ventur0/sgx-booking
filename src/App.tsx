import { Navigate, Route, Routes } from "react-router-dom";
import { StudioLayout } from "./pages/client/StudioLayout";
import { HomePage } from "./pages/client/HomePage";
import { ServicesPage } from "./pages/client/ServicesPage";
import { MyDetailPage, MyListPage } from "./pages/client/MyPage";
import { PrivacyPage } from "./pages/client/PrivacyPage";
import { OwnerPage } from "./pages/owner/OwnerPage";
import { Empty } from "./components/ui/States";

export function App() {
  return (
    <Routes>
      <Route path="/s/:slug" element={<StudioLayout />}>
        <Route index element={<HomePage />} />
        <Route path="services" element={<ServicesPage />} />
        <Route path="my" element={<MyListPage />} />
        <Route path="my/:id" element={<MyDetailPage />} />
        <Route path="privacy" element={<PrivacyPage />} />
        <Route path="owner/*" element={<OwnerPage />} />
        <Route path="*" element={<Navigate to="." replace />} />
      </Route>
      <Route path="*" element={<main className="wrap pad-top"><Empty>Откройте ссылку студии вида /s/название/, которую вам прислали.</Empty></main>} />
    </Routes>
  );
}
