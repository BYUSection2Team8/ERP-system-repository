import type { ComponentType } from 'react';
import { DashboardPage } from '../features/dashboard/DashboardPage';
import { AboutPage } from '../features/about/AboutPage';

// Route registry: the single place that lists every screen.
// The sidebar is generated from this list, so adding a module = one folder in
// src/features/ + one entry here. Later phases add inventory, pos, sales, etc.
export interface AppRoute {
  path: string;
  label: string;
  section: 'Overview' | 'Sales' | 'Operations' | 'Purchasing' | 'Finance' | 'System';
  component: ComponentType;
}

export const routes: AppRoute[] = [
  { path: '/', label: 'Dashboard', section: 'Overview', component: DashboardPage },
  { path: '/about', label: 'About this system', section: 'System', component: AboutPage },
];
