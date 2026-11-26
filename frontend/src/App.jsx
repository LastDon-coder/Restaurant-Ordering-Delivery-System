import { Navigate, Route, Routes } from 'react-router-dom';
import Layout from './components/Layout';
import ProtectedRoute from './components/ProtectedRoute';
import AdminMenuPage from './pages/AdminMenuPage';
import AdminRefundsPage from './pages/AdminRefundsPage';
import RestaurantShell from './components/RestaurantShell';
import RestaurantSettingsPage from './pages/RestaurantSettingsPage';
import RestaurantTeamPage from './pages/RestaurantTeamPage';
import { RestaurantDeliveryPage, RestaurantMenuPage } from './pages/RestaurantManagePages';
import StaffEntry from './components/StaffEntry';
import ApplyPage from './pages/ApplyPage';
import AdminRestaurantsPage from './pages/AdminRestaurantsPage';
import AdminUsersPage from './pages/AdminUsersPage';
import AdminDeliveryPage from './pages/AdminDeliveryPage';
import ReviewsPage from './pages/ReviewsPage';
import SetPasswordPage from './pages/SetPasswordPage';
import ForgotPasswordPage from './pages/ForgotPasswordPage';
import ResetPasswordPage from './pages/ResetPasswordPage';
import RiderPage from './pages/RiderPage';
import CartPage from './pages/CartPage';
import CheckoutPage from './pages/CheckoutPage';
import MyOrdersPage from './pages/MyOrdersPage';
import OrderPage from './pages/OrderPage';
import StaffOrdersPage from './pages/StaffOrdersPage';
import PaymentCallbackPage from './pages/PaymentCallbackPage';
import LoginPage from './pages/LoginPage';
import HomePage from './pages/HomePage';
import RestaurantPage from './pages/RestaurantPage';
import NotFoundPage from './pages/NotFoundPage';
import RegisterPage from './pages/RegisterPage';

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<HomePage />} />
        <Route path="r/:slug" element={<RestaurantPage />} />
        <Route path="login" element={<LoginPage />} />
        <Route path="register" element={<RegisterPage />} />
        <Route path="set-password" element={<SetPasswordPage />} />
        <Route path="forgot-password" element={<ForgotPasswordPage />} />
        <Route path="reset-password" element={<ResetPasswordPage />} />
        <Route element={<ProtectedRoute roles={['customer']} />}>
          <Route path="apply" element={<ApplyPage />} />
          <Route path="cart" element={<CartPage />} />
          <Route path="checkout/:restaurantId" element={<CheckoutPage />} />
          <Route path="checkout" element={<Navigate to="/cart" replace />} />
          <Route path="orders" element={<MyOrdersPage />} />
          <Route path="orders/:id" element={<OrderPage />} />
          <Route path="payment/callback" element={<PaymentCallbackPage />} />
        </Route>
        <Route element={<ProtectedRoute roles={['staff']} />}>
          <Route path="restaurant" element={<RestaurantShell />}>
            <Route index element={<RestaurantSettingsPage />} />
            <Route path="orders" element={<StaffOrdersPage />} />
            <Route path="reviews" element={<ReviewsPage />} />
            <Route path="menu" element={<RestaurantMenuPage />} />
            <Route path="delivery" element={<RestaurantDeliveryPage />} />
            <Route path="team" element={<RestaurantTeamPage />} />
          </Route>
        </Route>
        <Route element={<ProtectedRoute roles={['staff', 'admin']} />}>
          <Route path="staff/orders" element={<StaffEntry to="/restaurant/orders"><StaffOrdersPage /></StaffEntry>} />
          <Route path="staff/reviews" element={<StaffEntry to="/restaurant/reviews"><ReviewsPage /></StaffEntry>} />
        </Route>
        <Route element={<ProtectedRoute roles={['admin']} />}>
          <Route path="admin/menu" element={<AdminMenuPage />} />
          <Route path="admin/delivery" element={<AdminDeliveryPage />} />
          <Route path="admin/refunds" element={<AdminRefundsPage />} />
          <Route path="admin/restaurants" element={<AdminRestaurantsPage />} />
          <Route path="admin/users" element={<AdminUsersPage />} />
        </Route>
        <Route element={<ProtectedRoute roles={['rider']} />}>
          <Route path="rider" element={<RiderPage />} />
        </Route>
        {/* Next steps add: cart, checkout, orders (customer), admin/staff and rider dashboards behind <ProtectedRoute roles=[...]> */}
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
