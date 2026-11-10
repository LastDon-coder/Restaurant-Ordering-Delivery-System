import { useEffect } from 'react';
import { useLocation } from 'react-router-dom';

// The public address of the site, no trailing slash. Change it when you get a custom domain
// (set VITE_SITE_URL in Vercel, or edit the fallback below).
const SITE = (import.meta.env.VITE_SITE_URL || 'https://restaurant-ordering-delivery.vercel.app').replace(/\/+$/, '');

// Keeps <link rel="canonical"> pointing at the current page's clean address.
// WHY here and not in index.html: this is a single-page app, so every route is served by the SAME index.html.
// A fixed canonical there would tell Google that /login and /register are duplicates of the menu page.
// The query string and #hash are dropped, so /?ref=ad and / count as one page.
export function useCanonical() {
  const { pathname } = useLocation();
  useEffect(() => {
    const path = pathname === '/' ? '/' : pathname.replace(/\/+$/, '');
    let link = document.head.querySelector('link[rel="canonical"]');
    if (!link) {
      link = document.createElement('link');
      link.setAttribute('rel', 'canonical');
      document.head.appendChild(link);
    }
    link.setAttribute('href', SITE + path);
  }, [pathname]);
}
