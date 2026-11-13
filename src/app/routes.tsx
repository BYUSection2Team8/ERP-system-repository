import type { ComponentType } from 'react';
import { DashboardPage } from '../features/dashboard/DashboardPage';
import { AboutPage } from '../features/about/AboutPage';
import { InventoryPage } from '../features/inventory/InventoryPage';
import { ItemDetailPage } from '../features/inventory/ItemDetailPage';
import { TransferPage } from '../features/inventory/TransferPage';
import { AdjustPage } from '../features/inventory/AdjustPage';
import { BackordersPage } from '../features/inventory/BackordersPage';
import { LabelsPage } from '../features/barcodes/LabelsPage';
import { PosPage } from '../features/sales/PosPage';
import { SalesOrdersPage } from '../features/sales/SalesOrdersPage';
import { NewSalesOrderPage } from '../features/sales/NewSalesOrderPage';
import { SalesOrderDetailPage } from '../features/sales/SalesOrderDetailPage';
import { ReceiptPage } from '../features/sales/Receipt';
import { ProductionOrdersPage } from '../features/production/ProductionOrdersPage';
import { NewProductionOrderPage } from '../features/production/NewProductionOrderPage';
import { ProductionOrderDetailPage } from '../features/production/ProductionOrderDetailPage';
import { ProductionReportPage } from '../features/production/ProductionReportPage';
import { MrpPage } from '../features/mrp/MrpPage';

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
  { path: '/pos', label: 'Point of sale', section: 'Sales', component: PosPage },
  { path: '/sales', label: 'Sales orders', section: 'Sales', component: SalesOrdersPage },
  { path: '/sales/new', label: 'New sales order', section: 'Sales', component: NewSalesOrderPage },
  { path: '/sales/:id', label: 'Sales order', section: 'Sales', component: SalesOrderDetailPage, hidden: true },
  { path: '/sales/:id/receipt', label: 'Receipt', section: 'Sales', component: ReceiptPage, hidden: true },
  { path: '/inventory', label: 'Inventory', section: 'Operations', component: InventoryPage },
  { path: '/inventory/item/:id', label: 'Item', section: 'Operations', component: ItemDetailPage, hidden: true },
  { path: '/inventory/transfer', label: 'Transfers', section: 'Operations', component: TransferPage },
  { path: '/inventory/adjust', label: 'Adjust & count', section: 'Operations', component: AdjustPage },
  { path: '/inventory/backorders', label: 'Backorders', section: 'Operations', component: BackordersPage },
  { path: '/labels', label: 'Barcode labels', section: 'Operations', component: LabelsPage },
  { path: '/production', label: 'Production orders', section: 'Operations', component: ProductionOrdersPage },
  { path: '/production/new', label: 'New production order', section: 'Operations', component: NewProductionOrderPage, hidden: true },
  { path: '/production/report', label: 'Production report', section: 'Operations', component: ProductionReportPage },
  { path: '/production/:id', label: 'Production order', section: 'Operations', component: ProductionOrderDetailPage, hidden: true },
  { path: '/mrp', label: 'MRP', section: 'Purchasing', component: MrpPage },
  { path: '/about', label: 'About this system', section: 'System', component: AboutPage },
];
