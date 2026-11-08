import { Route, Routes } from 'react-router-dom';
import Layout from './components/Layout';
import ProtectedRoute from './components/ProtectedRoute';
import AdminMenuPage from './pages/AdminMenuPage';
import AdminRefundsPage from './pages/AdminRefundsPage';
import AdminUsersPage from './pages/AdminUsersPage';
import RiderPage from './pages/RiderPage';
import CartPage from './pages/CartPage';
import CheckoutPage from './pages/CheckoutPage';
import MyOrdersPage from './pages/MyOrdersPage';
import OrderPage from './pages/OrderPage';
import StaffOrdersPage from './pages/StaffOrdersPage';
import PaymentCallbackPage from './pages/PaymentCallbackPage';
import LoginPage from './pages/LoginPage';
import MenuPage from './pages/MenuPage';
import NotFoundPage from './pages/NotFoundPage';
import RegisterPage from './pages/RegisterPage';

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<MenuPage />} />
        <Route path="login" element={<LoginPage />} />
        <Route path="register" element={<RegisterPage />} />
        <Route element={<ProtectedRoute roles={['customer']} />}>
          <Route path="cart" element={<CartPage />} />
          <Route path="checkout" element={<CheckoutPage />} />
          <Route path="orders" element={<MyOrdersPage />} />
          <Route path="orders/:id" element={<OrderPage />} />
          <Route path="payment/callback" element={<PaymentCallbackPage />} />
        </Route>
        <Route element={<ProtectedRoute roles={['staff', 'admin']} />}>
          <Route path="staff/orders" element={<StaffOrdersPage />} />
        </Route>
        <Route element={<ProtectedRoute roles={['admin']} />}>
          <Route path="admin/menu" element={<AdminMenuPage />} />
          <Route path="admin/refunds" element={<AdminRefundsPage />} />
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
