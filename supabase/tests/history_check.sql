-- =============================================================================
-- history_check.sql — Phase 6: 60 customers and 6 months of DERIVED history.
-- Read-only. Run after seed/002_customers_history.sql has said COMPLETE.
-- Success = "HISTORY CHECKS PASSED".
--
-- Rubric "Starting Data": >= 10 customers, >= 6 months of sales history that
-- varies realistically across items and time (not flat, not purely random),
-- every balance derived from transactions.
-- =============================================================================
do $$
declare
  v_start date := (select value::date from settings where key = 'history_start_date');
  v_months int;
  v_min numeric; v_max numeric;
  v_mean numeric; v_sd numeric;
  v_inv numeric; v_val numeric;
  r record;
begin
  if not exists (select 1 from settings where key = 'history_complete' and value = 'true') then
    raise exception 'History is not complete yet: run seed/002_customers_history.sql again until it says COMPLETE.';
  end if;

  -- ------------------------------------------------------------ customers
  assert (select count(*) from customers where name <> 'Demo Customer') = 60,
    format('60 customers (have %s)', (select count(*) from customers where name <> 'Demo Customer'));
  assert (select count(*) from customers where notes like '%portal login%') = 12, '11 portal logins + the demo customer';
  assert (select count(distinct segment) from customers) = 5, 'five customer segments';
  assert (select count(*) from customers c where exists (select 1 from sales_orders s where s.customer_id = c.id)) >= 50,
    'most customers have ordered';

  -- ------------------------------------------------------- 6 months of sales
  assert v_start <= (now() at time zone 'America/Denver')::date - 175, format('history starts %s', v_start);
  select count(*) into v_months
    from (select date_trunc('month', order_date) from sales_orders
           where status <> 'cancelled' group by 1 having count(*) >= 30) m;
  assert v_months >= 6, format('at least 6 months with 30+ orders (have %s)', v_months);
  assert (select count(*) from sales_orders where status in ('fulfilled', 'closed')) >= 1000,
    format('1,000+ completed sales (have %s)', (select count(*) from sales_orders where status in ('fulfilled', 'closed')));
  assert (select count(distinct l.item_id) from sales_order_lines l join sales_orders s on s.id = l.so_id
           where s.status in ('fulfilled', 'closed')) >= 26, 'sales across nearly every product variant';
  assert (select count(*) from sales_orders where channel = 'pos') >= 100, 'campus counter (POS) sales';
  assert (select count(*) from sales_orders where payment_method = 'account') >= 10, 'business orders on account';

  -- Not flat: weekly units vary (season, trend, events) ...
  select avg(u), stddev_samp(u) into v_mean, v_sd
    from (select date_trunc('week', s.order_date) as w, sum(l.qty) as u
            from sales_orders s join sales_order_lines l on l.so_id = s.id
           where s.status <> 'cancelled' and s.order_date >= (v_start + 7)::timestamptz
             and s.order_date < date_trunc('week', now())
           group by 1) x;
  assert v_sd / v_mean >= 0.15, format('weekly units vary (coefficient of variation %s)', round(v_sd / v_mean, 3));
  -- ... and the mix differs by item: best seller sells 5x+ the slowest product.
  select min(u), max(u) into v_min, v_max
    from (select i.product_family, sum(l.qty) as u
            from sales_order_lines l join sales_orders s on s.id = l.so_id join items i on i.id = l.item_id
           where s.status in ('fulfilled', 'closed') and i.product_family <> 'Christmas Ornament'
           group by 1) x;
  assert v_max >= 5 * v_min, format('product mix varies (min %s, max %s units)', v_min, v_max);
  -- Seasonality: back-to-school September beats July for student products.
  assert (select sum(l.qty) from sales_order_lines l join sales_orders s on s.id = l.so_id join customers c on c.id = s.customer_id
           where c.segment = 'student' and extract(month from s.order_date) = 9)
       > (select coalesce(sum(l.qty), 0) from sales_order_lines l join sales_orders s on s.id = l.so_id join customers c on c.id = s.customer_id
           where c.segment = 'student' and extract(month from s.order_date) = 7),
    'students buy more in September than July';

  -- ---------------------------------------------- production and purchasing
  assert (select count(*) from production_orders where status = 'completed') >= 150, 'production history';
  assert (select count(*) from production_orders where status = 'completed' and qty_scrap > 0) >= 10, 'some print failures';
  assert (select count(distinct scrap_reason) from production_orders where qty_scrap > 0) >= 4, 'several failure reasons';
  for r in select s.name, count(po.id) as n from suppliers s
             left join purchase_orders po on po.supplier_id = s.id and po.status in ('received', 'closed', 'partial')
            group by s.name loop
    assert r.n >= 2, format('%s has PO history (%s received)', r.name, r.n);
  end loop;
  assert exists (select 1 from purchase_orders po join po_receipts rc on rc.po_id = po.id
                  where (rc.received_at at time zone 'America/Denver')::date > po.expected_date), 'some deliveries were late';
  assert exists (select 1 from purchase_orders po
                  where po.status = 'closed'
                    and exists (select 1 from purchase_order_lines l where l.po_id = po.id and l.qty_received < l.qty_ordered)),
    'some POs were closed short (fill rate < 100%)';
  assert (select count(*) from po_receipts) > (select count(*) from purchase_orders where status in ('received', 'closed')),
    'some POs arrived in more than one shipment';
  assert (select coalesce(sum(balance), 0) from v_ap_open) > 0, 'open supplier bills (amounts owed)';
  assert (select count(*) from supplier_payments) >= 20, 'supplier payments recorded';
  assert (select count(*) from returns) >= 10, 'returns and exchanges';
  assert exists (select 1 from returns where return_type = 'exchange'), 'at least one exchange';
  assert exists (select 1 from return_lines where disposition = 'qa_hold'), 'quality returns went to QA Hold';
  assert exists (select 1 from inventory_txn where source_type = 'transfer_in'), 'delivery runs to campus';
  assert exists (select 1 from inventory_txn where source_type = 'adjustment'), 'cycle counts and adjustments';

  -- ------------------------------------------------- MRP has work to plan
  assert (select count(*) from sales_orders where status = 'placed' and need_date > (now() at time zone 'America/Denver')::date) >= 5,
    'open orders with future need dates for MRP';

  -- ----------------------------------------------- the books are consistent
  assert (select sum(debit) from ledger) = (select sum(credit) from ledger), 'ledger balances';
  assert not exists (select 1 from inventory_txn group by item_id, location_id having sum(qty) < 0), 'no negative stock';
  v_inv := (select balance from v_account_balances where code = '1200');
  v_val := (select sum(inventory_value) from v_inventory_valuation);
  assert abs(v_inv - v_val) <= greatest(5, 0.01 * v_val),
    format('inventory on the books %s vs weighted-average valuation %s', v_inv, v_val);
  assert (select balance from v_account_balances where code = '4000') > 10000, 'meaningful sales revenue';

  raise notice 'HISTORY CHECKS PASSED: % customers, % sales orders since %, % production orders, % purchase orders; inventory $% (valuation $%)',
    (select count(*) from customers), (select count(*) from sales_orders), v_start,
    (select count(*) from production_orders), (select count(*) from purchase_orders), v_inv, round(v_val, 2);
end $$;
