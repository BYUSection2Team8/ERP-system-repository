import type { ComponentType } from 'react';
import { DashboardPage } from '../features/dashboard/DashboardPage';
import { AboutPage } from '../features/about/AboutPage';
import { InventoryPage } from '../features/inventory/InventoryPage';
import { ItemDetailPage } from '../features/inventory/ItemDetailPage';
import { TransferPage } from '../features/inventory/TransferPage';
import { AdjustPage } from '../features/inventory/AdjustPage';
import { BackordersPage } from '../features/inventory/BackordersPage';
import { LabelsPage } from '../features/barcodes/LabelsPage';

// Route registry: the single place that lists every screen.
// The sidebar is generated from this list, so adding a module = one folder in
// src/features/ + one entry here. `hidden` routes (detail pages) are not in the menu.
export interface AppRoute {
  path: string;
  label: string;
  section: 'Overview' | 'Sales' | 'Operations' | 'Purchasing' | 'Finance' | 'System';
  component: ComponentType;
  hidden?: boolean;
}

export const routes: AppRoute[] = [
  { path: '/', label: 'Dashboard', section: 'Overview', component: DashboardPage },
  { path: '/inventory', label: 'Inventory', section: 'Operations', component: InventoryPage },
  { path: '/inventory/item/:id', label: 'Item', section: 'Operations', component: ItemDetailPage, hidden: true },
  { path: '/inventory/transfer', label: 'Transfers', section: 'Operations', component: TransferPage },
  { path: '/inventory/adjust', label: 'Adjust & count', section: 'Operations', component: AdjustPage },
  { path: '/inventory/backorders', label: 'Backorders', section: 'Operations', component: BackordersPage },
  { path: '/labels', label: 'Barcode labels', section: 'Operations', component: LabelsPage },
  { path: '/about', label: 'About this system', section: 'System', component: AboutPage },
];
